import cv2
import numpy as np
import matplotlib.pyplot as plt
import sys
import os


def cargarImagen(ruta):
    if not os.path.exists(ruta):
        print(f"Error: La ruta '{ruta}' no existe.")
        sys.exit(1)

    original = cv2.imread(ruta)
    if original is None:
        print(f"Error: No se pudo cargar la imagen en la ruta '{ruta}'")
        sys.exit(1)

    return original


def segmentarImagen(gris):
    valorUmbral = 127
    _, umbralBasico = cv2.threshold(gris, valorUmbral, 255, cv2.THRESH_BINARY)

    umbralCalculado, umbralOtsu = cv2.threshold(
        gris, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    print(f"El umbral óptimo calculado por Otsu es: {umbralCalculado}")

    return umbralBasico, umbralOtsu, valorUmbral, umbralCalculado


def limpiarTexto(imagenColor, tamanoKernel=5, iteraciones=3):
    """
    Aplica un cierre morfológico repetido (dilatación + erosión) para
    'borrar' el texto y quedarnos con una hoja casi en blanco.

    Se aplica sobre la imagen A COLOR porque el siguiente paso (GrabCut)
    necesita una imagen de 3 canales.
    """
    kernel = np.ones((tamanoKernel, tamanoKernel), np.uint8)
    hojaLimpia = cv2.morphologyEx(
        imagenColor, cv2.MORPH_CLOSE, kernel, iterations=iteraciones
    )
    return hojaLimpia


def quitarFondo(imagenLimpia, margen=20, iteraciones=5):
    """
    Usa GrabCut para eliminar el fondo y quedarnos solo con el documento.
    """
    alto, ancho = imagenLimpia.shape[:2]

    mascara = np.zeros((alto, ancho), np.uint8)
    modeloFondo = np.zeros((1, 65), np.float64)
    modeloFrente = np.zeros((1, 65), np.float64)

    rectangulo = (margen, margen, ancho - margen, alto - margen)

    cv2.grabCut(
        imagenLimpia,
        mascara,
        rectangulo,
        modeloFondo,
        modeloFrente,
        iteraciones,
        cv2.GC_INIT_WITH_RECT,
    )

    mascaraBinaria = np.where((mascara == 2) | (mascara == 0), 0, 1).astype("uint8")
    imagenSinFondo = imagenLimpia * mascaraBinaria[:, :, np.newaxis]

    return imagenSinFondo, mascaraBinaria


def detectarBordes(grisFinal):
    """
    Detección de bordes con Canny sobre la imagen ya sin texto ni fondo.
    """
    filtroBorde = cv2.GaussianBlur(grisFinal, (5, 5), 0)
    bordes = cv2.Canny(filtroBorde, 0, 200)
    bordes = cv2.dilate(
        bordes, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    )
    return bordes


def cross_product(p1: tuple, p2: tuple, p3: tuple) -> float:
    """Producto cruz para determinar la orientación de tres puntos."""
    return (p2[0] - p1[0]) * (p3[1] - p1[1]) - (p2[1] - p1[1]) * (p3[0] - p1[0])


def compute_convex_hull(points: list) -> list:
    """
    Calcula el casco convexo de un conjunto de puntos (x, y) usando el
    algoritmo Monotone Chain (Andrew's algorithm).

    Se usa para 'envolver' los puntos crudos del contorno del documento
    en un polígono limpio antes de simplificarlo con approxPolyDP. Esto
    ayuda cuando el contorno viene fragmentado o con muescas por sombras
    o ruido: el hull ignora las hendiduras internas y conserva solo el
    perímetro exterior real.
    """
    sorted_points = sorted(list(set(points)))
    if len(sorted_points) <= 3:
        return sorted_points

    lower = []
    for p in sorted_points:
        while len(lower) >= 2 and cross_product(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)

    upper = []
    for p in reversed(sorted_points):
        while len(upper) >= 2 and cross_product(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)

    return lower[:-1] + upper[:-1]


def ordenarPuntos(puntos):
    """
    Reordena las 4 esquinas en el orden estándar:
    superior-izq, superior-der, inferior-der, inferior-izq
    """
    rectangulo = np.zeros((4, 2), dtype="float32")
    puntos = np.array(puntos)

    suma = puntos.sum(axis=1)
    rectangulo[0] = puntos[np.argmin(suma)]  # menor suma → sup-izq
    rectangulo[2] = puntos[np.argmax(suma)]  # mayor suma → inf-der

    diferencia = np.diff(puntos, axis=1)
    rectangulo[1] = puntos[np.argmin(diferencia)]  # menor diff → sup-der
    rectangulo[3] = puntos[np.argmax(diferencia)]  # mayor diff → inf-izq

    return rectangulo.astype("int").tolist()


def contornoAConvexHull(contorno):
    """
    Convierte un contorno de OpenCV (array de forma Nx1x2) a su casco
    convexo, usando nuestra implementación propia (Monotone Chain), y
    lo regresa en el mismo formato que espera OpenCV para poder seguir
    usando cv2.arcLength / cv2.approxPolyDP sobre él.
    """
    puntosXY = [tuple(p[0]) for p in contorno]
    hull = compute_convex_hull(puntosXY)

    if len(hull) < 3:
        # Hull degenerado (puntos colineales, etc.) — devolvemos el
        # contorno original sin modificar para no romper el pipeline.
        return contorno

    return np.array(hull, dtype=np.int32).reshape((-1, 1, 2))


def detectarEsquinas(original, bordes):
    """
    Detecta las 4 esquinas del documento usando contornos + convex hull
    + approxPolyDP, en vez de cornerHarris. Es más robusto porque:
    - Solo considera el contorno de MAYOR ÁREA (asumiendo que el
      documento es el objeto más grande de la imagen).
    - El convex hull 'envuelve' el contorno en un polígono limpio,
      eliminando muescas y fragmentaciones causadas por sombras o ruido,
      antes de intentar reducirlo a 4 vértices.
    - Fuerza la aproximación a exactamente 4 vértices, en vez de
      devolver decenas de puntos "esquina" sueltos.
    """
    imagenMarcada = original.copy()

    contornos, _ = cv2.findContours(
        bordes, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE
    )

    if len(contornos) == 0:
        print("No se detectaron contornos. Se usa la imagen original sin marcar.")
        return imagenMarcada, []

    # Nos quedamos con los 5 contornos más grandes como candidatos.
    candidatos = sorted(contornos, key=cv2.contourArea, reverse=True)[:5]

    # Convertimos cada candidato a su casco convexo antes de simplificar.
    candidatosHull = [contornoAConvexHull(c) for c in candidatos]

    # Probamos varios valores de epsilon (de menos a más tolerante) para
    # cada contorno candidato, en vez de usar un único valor fijo.
    # Esto ayuda cuando las sombras o el ruido generan contornos irregulares
    # que con un solo epsilon no se reducen a exactamente 4 puntos.
    factoresEpsilon = [0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.09]

    esquinas = None
    for contorno in candidatosHull:
        perimetro = cv2.arcLength(contorno, True)
        for factor in factoresEpsilon:
            epsilon = factor * perimetro
            aproximacion = cv2.approxPolyDP(contorno, epsilon, True)
            if len(aproximacion) == 4:
                esquinas = aproximacion
                break
        if esquinas is not None:
            break

    if esquinas is None:
        print(
            "No se encontró un contorno con exactamente 4 esquinas, "
            "ni siquiera variando epsilon. Probablemente el contorno del "
            "documento está muy fragmentado (sombras, bajo contraste, etc.)."
        )
        return imagenMarcada, []

    # Convertir a lista de puntos (x, y) y ordenarlos.
    puntos = np.concatenate(esquinas).tolist()
    puntos = ordenarPuntos(puntos)

    # Dibujar el contorno y las esquinas sobre la imagen original.
    cv2.drawContours(imagenMarcada, [np.array(puntos)], -1, (0, 255, 255), 3)
    for (x, y) in puntos:
        cv2.circle(imagenMarcada, (int(x), int(y)), 10, (0, 0, 255), -1)

    etiquetas = ["Sup-Izq", "Sup-Der", "Inf-Der", "Inf-Izq"]
    for etiqueta, (x, y) in zip(etiquetas, puntos):
        cv2.putText(
            imagenMarcada, etiqueta, (int(x) + 12, int(y)),
            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 0, 0), 2, cv2.LINE_AA
        )

    # ── GUARDAR COORDENADAS (formato x, y por esquina) ─────────────────
    with open("coordenadas_esquinas.txt", "w") as archivo:
        archivo.write("# Coordenadas de las 4 esquinas del documento\n")
        archivo.write("# Formato: etiqueta, x, y\n")
        for etiqueta, (x, y) in zip(etiquetas, puntos):
            archivo.write(f"{etiqueta},{x},{y}\n")

    print(f"Esquinas detectadas: {len(puntos)}")
    print("Coordenadas guardadas en: coordenadas_esquinas.txt")
    # ─────────────────────────────────────────────────────────────────────

    return imagenMarcada, puntos


def encontrarDestino(esquinas):
    """
    Calcula las coordenadas destino (un rectángulo perfecto) a partir de
    las 4 esquinas detectadas, para saber a qué tamaño final se debe
    'enderezar' el documento.

    Se calculan el ancho y alto máximos posibles entre las esquinas
    (porque en la foto original el documento rara vez es un rectángulo
    perfecto: está inclinado o en perspectiva), y se arma un rectángulo
    de destino con esas medidas.
    """
    (tl, tr, br, bl) = esquinas

    anchoA = np.sqrt(((br[0] - bl[0]) ** 2) + ((br[1] - bl[1]) ** 2))
    anchoB = np.sqrt(((tr[0] - tl[0]) ** 2) + ((tr[1] - tl[1]) ** 2))
    anchoMaximo = max(int(anchoA), int(anchoB))

    altoA = np.sqrt(((tr[0] - br[0]) ** 2) + ((tr[1] - br[1]) ** 2))
    altoB = np.sqrt(((tl[0] - bl[0]) ** 2) + ((tl[1] - bl[1]) ** 2))
    altoMaximo = max(int(altoA), int(altoB))

    coordenadasDestino = [
        [0, 0],
        [anchoMaximo, 0],
        [anchoMaximo, altoMaximo],
        [0, altoMaximo],
    ]

    return ordenarPuntos(coordenadasDestino)


def enderezarDocumento(original, esquinas, destino):
    """
    Aplica la transformación de perspectiva (homografía) para 'enderezar'
    el documento: lo alinea y lo recorta según las esquinas detectadas.
    """
    matrizHomografia = cv2.getPerspectiveTransform(
        np.float32(esquinas), np.float32(destino)
    )

    documentoFinal = cv2.warpPerspective(
        original,
        matrizHomografia,
        (destino[2][0], destino[2][1]),
        flags=cv2.INTER_LINEAR,
    )

    return documentoFinal


def procesarImagen(ruta):
    original = cargarImagen(ruta)
    gris = cv2.cvtColor(original, cv2.COLOR_BGR2GRAY)

    umbralBasico, umbralOtsu, valorUmbral, umbralCalculado = segmentarImagen(gris)

    # Paso 1: "borrar" el texto de la hoja (sobre la imagen a color)
    imagenLimpia = limpiarTexto(original, tamanoKernel=5, iteraciones=3)

    # Paso 2: quitar el fondo con GrabCut
    imagenSinFondo, mascara = quitarFondo(imagenLimpia, margen=20, iteraciones=5)

    # Paso 3: pasar a grises para detectar bordes
    grisFinal = cv2.cvtColor(imagenSinFondo, cv2.COLOR_BGR2GRAY)

    # Paso 4: detección de bordes (Canny)
    bordes = detectarBordes(grisFinal)

    # Paso 5: detección de esquinas por contornos + approxPolyDP
    imagenMarcada, esquinas = detectarEsquinas(original, bordes)

    # Paso 6: perspective transform para enderezar el documento
    if len(esquinas) == 4:
        destino = encontrarDestino(esquinas)
        documentoFinal = enderezarDocumento(original, esquinas, destino)
        cv2.imwrite("documento_enderezado.png", documentoFinal)
        print("Documento enderezado guardado en: documento_enderezado.png")
    else:
        print(
            "No se pudieron detectar las 4 esquinas; se omite el "
            "enderezado del documento (paso 6)."
        )
        documentoFinal = original.copy()

    originalRGB = cv2.cvtColor(original, cv2.COLOR_BGR2RGB)
    imagenLimpiaRGB = cv2.cvtColor(imagenLimpia, cv2.COLOR_BGR2RGB)
    imagenSinFondoRGB = cv2.cvtColor(imagenSinFondo, cv2.COLOR_BGR2RGB)
    imagenMarcadaRGB = cv2.cvtColor(imagenMarcada, cv2.COLOR_BGR2RGB)
    documentoFinalRGB = cv2.cvtColor(documentoFinal, cv2.COLOR_BGR2RGB)

    titulos = [
        "Imagen Original",
        "Hoja sin texto (Morfología)",
        "Sin fondo (GrabCut)",
        "Escala de Grises Final",
        "Detector de Bordes (Canny)",
        "Esquinas (Contornos + approxPolyDP)",
        "Documento Enderezado (Perspective Transform)",
    ]
    imagenes = [
        originalRGB,
        imagenLimpiaRGB,
        imagenSinFondoRGB,
        grisFinal,
        bordes,
        imagenMarcadaRGB,
        documentoFinalRGB,
    ]
    mapasColor = [None, None, None, "gray", "gray", None, None]

    plt.figure(figsize=(15, 10))
    for i in range(7):
        plt.subplot(3, 3, i + 1)
        plt.imshow(imagenes[i], cmap=mapasColor[i])
        plt.title(titulos[i])
        plt.axis("off")

    plt.tight_layout()
    plt.show(block=True)

    return esquinas, documentoFinal


# --- EJECUCIÓN ---
if __name__ == "__main__":
    rutaImagen = sys.argv[1] if len(sys.argv) > 1 else "imagenes/IMG_20260704_150429.jpg"
    procesarImagen(rutaImagen)