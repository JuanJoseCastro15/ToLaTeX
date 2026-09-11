"""
procesador_documento_comparacion.py

Archivo único e independiente (no requiere importar procesador_documento.py).
Contiene TODO el pipeline de detección/enderezado del documento, y además
muestra y guarda una comparación lado a lado de:
  - Antes: la foto original tal cual se cargó.
  - Después: el documento ya enderezado/recortado (perspective transform).

Uso:
    python procesador_documento_comparacion.py ruta_de_la_foto.jpg
"""

import cv2
import numpy as np
import matplotlib.pyplot as plt
import math
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


def limpiarTexto(imagenColor, tamanoKernel=5, iteraciones=3):
    kernel = np.ones((tamanoKernel, tamanoKernel), np.uint8)
    hojaLimpia = cv2.morphologyEx(
        imagenColor, cv2.MORPH_CLOSE, kernel, iterations=iteraciones
    )
    return hojaLimpia


def quitarFondo(imagenLimpia, margen=20, iteraciones=5):
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
    filtroBorde = cv2.GaussianBlur(grisFinal, (5, 5), 0)
    bordes = cv2.Canny(filtroBorde, 0, 200)
    bordes = cv2.dilate(
        bordes, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    )
    return bordes


def cross_product(p1, p2, p3):
    return (p2[0] - p1[0]) * (p3[1] - p1[1]) - (p2[1] - p1[1]) * (p3[0] - p1[0])


def compute_convex_hull(points):
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
    rectangulo = np.zeros((4, 2), dtype="float32")
    puntos = np.array(puntos)

    suma = puntos.sum(axis=1)
    rectangulo[0] = puntos[np.argmin(suma)]
    rectangulo[2] = puntos[np.argmax(suma)]

    diferencia = np.diff(puntos, axis=1)
    rectangulo[1] = puntos[np.argmin(diferencia)]
    rectangulo[3] = puntos[np.argmax(diferencia)]

    return rectangulo.astype("int").tolist()


def contornoAConvexHull(contorno):
    puntosXY = [tuple(p[0]) for p in contorno]
    hull = compute_convex_hull(puntosXY)

    if len(hull) < 3:
        return contorno

    return np.array(hull, dtype=np.int32).reshape((-1, 1, 2))


def detectarBordesAlterno(gris):
    """
    Método de respaldo para encontrar bordes, sin depender de GrabCut.
    Usa el umbral automático de Otsu para calibrar los límites de Canny
    según el contraste real de cada imagen, en vez de usar los valores
    fijos (0, 200). Sirve para cuando GrabCut falla (por ejemplo, si el
    fondo es muy parecido en color/tono a la hoja).
    """
    filtroBorde = cv2.GaussianBlur(gris, (5, 5), 0)
    umbralOtsu, _ = cv2.threshold(
        filtroBorde, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    bordes = cv2.Canny(filtroBorde, umbralOtsu * 0.5, umbralOtsu)
    bordes = cv2.dilate(
        bordes, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    )
    return bordes


def anguloEnVertice(p0, p1, p2):
    """Ángulo interno (en grados) que se forma en el punto p1, entre
    los segmentos p1->p0 y p1->p2."""
    v1 = (p0[0] - p1[0], p0[1] - p1[1])
    v2 = (p2[0] - p1[0], p2[1] - p1[1])
    mag1 = math.hypot(*v1)
    mag2 = math.hypot(*v2)
    if mag1 == 0 or mag2 == 0:
        return 0.0
    coseno = (v1[0] * v2[0] + v1[1] * v2[1]) / (mag1 * mag2)
    coseno = max(-1.0, min(1.0, coseno))  # evitar errores de redondeo fuera de [-1,1]
    return math.degrees(math.acos(coseno))


def validarCuadrilatero(puntos, anchoImagen, altoImagen,
                         fraccionAreaMin=0.15, fraccionAreaMax=0.97,
                         anguloMin=45, anguloMax=135):
    """
    Revisa que un cuadrilátero candidato realmente tenga pinta de ser
    una hoja de papel fotografiada, para no aceptar cualquier forma de
    4 puntos que encuentre approxPolyDP (que a veces agarra basura del
    fondo y termina empeorando la imagen en vez de mejorarla).

    Se valida:
      1) Que el área del cuadrilátero sea una fracción razonable del
         área total de la imagen (ni un rectángulo diminuto de ruido,
         ni casi toda la foto de borde a borde).
      2) Que sus 4 ángulos internos sean razonablemente rectos (entre
         45° y 135°), para descartar formas tipo "cometa" o muy
         alargadas que no corresponden a una hoja vista en perspectiva.

    Regresa (es_valido, fraccion_area) para poder comparar candidatos
    entre sí y quedarnos con el mejor.
    """
    areaImagen = float(anchoImagen * altoImagen)
    areaCuadrilatero = cv2.contourArea(np.array(puntos, dtype=np.float32))
    fraccion = areaCuadrilatero / areaImagen if areaImagen > 0 else 0

    if not (fraccionAreaMin <= fraccion <= fraccionAreaMax):
        return False, fraccion

    n = len(puntos)
    for i in range(n):
        p0 = puntos[i - 1]
        p1 = puntos[i]
        p2 = puntos[(i + 1) % n]
        angulo = anguloEnVertice(p0, p1, p2)
        if angulo < anguloMin or angulo > anguloMax:
            return False, fraccion

    return True, fraccion


def detectarEsquinas(original, bordes):
    """
    Detecta las 4 esquinas del documento probando varios contornos
    candidatos y varios valores de epsilon, PERO a diferencia de
    quedarse con el primer cuadrilátero de 4 puntos que encuentra,
    ahora valida cada candidato geométricamente (ver validarCuadrilatero)
    y se queda con el que mejor pinta de "hoja de papel" tenga (mayor
    área válida). Esto evita aceptar detecciones erróneas que antes
    podían terminar empeorando la imagen en vez de enderezarla.
    """
    imagenMarcada = original.copy()
    altoImagen, anchoImagen = original.shape[:2]

    contornos, _ = cv2.findContours(
        bordes, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE
    )

    if len(contornos) == 0:
        print("No se detectaron contornos. Se usa la imagen original sin marcar.")
        return imagenMarcada, []

    # Probamos con más candidatos que antes (8 en vez de 5), ya que
    # ahora los filtramos con validarCuadrilatero y no con solo tomar
    # el primero que aparezca.
    candidatos = sorted(contornos, key=cv2.contourArea, reverse=True)[:8]
    candidatosHull = [contornoAConvexHull(c) for c in candidatos]

    factoresEpsilon = [0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.09, 0.12]

    mejoresPuntos = None
    mejorFraccion = 0.0

    for contorno in candidatosHull:
        perimetro = cv2.arcLength(contorno, True)
        for factor in factoresEpsilon:
            epsilon = factor * perimetro
            aproximacion = cv2.approxPolyDP(contorno, epsilon, True)
            if len(aproximacion) != 4:
                continue

            puntosCandidatos = ordenarPuntos(np.concatenate(aproximacion).tolist())
            esValido, fraccion = validarCuadrilatero(
                puntosCandidatos, anchoImagen, altoImagen
            )

            if esValido and fraccion > mejorFraccion:
                mejorFraccion = fraccion
                mejoresPuntos = puntosCandidatos

    if mejoresPuntos is None:
        print(
            "No se encontró ningún cuadrilátero que pase las validaciones "
            "de forma (área y ángulos razonables de una hoja)."
        )
        return imagenMarcada, []

    print(f"Documento detectado: cubre ~{mejorFraccion * 100:.1f}% de la imagen de trabajo.")
    return imagenMarcada, mejoresPuntos


def encontrarDestino(esquinas):
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


def procesarImagen(ruta, guardar=True, dimensionLimite=1080):
    """
    Pipeline completo: recibe la ruta de la foto original y regresa
    la imagen del documento ya enderezado/recortado (documentoFinal).
    Si no se detectan las 4 esquinas, regresa la imagen original tal cual.

    Para la DETECCIÓN (morfología + GrabCut + Canny + contornos) se
    trabaja sobre una copia reducida a un máximo de 'dimensionLimite'
    píxeles en su lado más grande. Esto es más rápido (GrabCut es lento
    en fotos grandes) y más estable, porque hay menos ruido a esa
    resolución. Las esquinas detectadas se reescalan de vuelta antes
    de hacer el warpPerspective, así que el resultado final SÍ se
    genera en la resolución original de la foto, sin perder calidad.
    """
    original = cargarImagen(ruta)
    altoOriginal, anchoOriginal = original.shape[:2]
    dimensionMaxima = max(altoOriginal, anchoOriginal)

    if dimensionMaxima > dimensionLimite:
        escala = dimensionLimite / dimensionMaxima
        imagenTrabajo = cv2.resize(
            original, None, fx=escala, fy=escala, interpolation=cv2.INTER_AREA
        )
    else:
        escala = 1.0
        imagenTrabajo = original.copy()

    imagenLimpia = limpiarTexto(imagenTrabajo, tamanoKernel=5, iteraciones=3)
    imagenSinFondo, _ = quitarFondo(imagenLimpia, margen=20, iteraciones=5)
    grisFinal = cv2.cvtColor(imagenSinFondo, cv2.COLOR_BGR2GRAY)
    bordes = detectarBordes(grisFinal)
    _, esquinas = detectarEsquinas(imagenTrabajo, bordes)

    if len(esquinas) != 4:
        # Método de respaldo: si GrabCut + Canny no encontraron un
        # cuadrilátero válido (por ejemplo porque el fondo es muy
        # parecido a la hoja y GrabCut no logró separarlos bien),
        # reintentamos SIN GrabCut, usando el umbral automático de
        # Otsu para calibrar Canny según el contraste real de la foto.
        print("Reintentando con el método alterno (sin GrabCut)...")
        grisAlterno = cv2.cvtColor(imagenLimpia, cv2.COLOR_BGR2GRAY)
        bordesAlterno = detectarBordesAlterno(grisAlterno)
        _, esquinas = detectarEsquinas(imagenTrabajo, bordesAlterno)

    if len(esquinas) == 4:
        # Reescalamos las esquinas (detectadas en la imagen reducida)
        # de vuelta a coordenadas de la imagen ORIGINAL en full resolución.
        esquinasOriginal = [[x / escala, y / escala] for x, y in esquinas]
        destino = encontrarDestino(esquinasOriginal)
        documentoFinal = enderezarDocumento(original, esquinasOriginal, destino)
        print("Documento detectado y enderezado correctamente.")
    else:
        print(
            "No se encontró una detección confiable con ninguno de los dos "
            "métodos; se usa la imagen original sin modificar (más seguro "
            "que aplicar una transformación incorrecta)."
        )
        documentoFinal = original.copy()

    if guardar:
        cv2.imwrite("documento_enderezado.png", documentoFinal)
        print("Guardado como: documento_enderezado.png")

    return documentoFinal


def mostrarAntesDespues(ruta, dimensionLimite=1080):
    """
    Corre el pipeline completo y muestra/guarda una comparación lado a
    lado de la foto original (antes) contra el documento ya enderezado
    (después).
    """
    original = cargarImagen(ruta)
    documentoFinal = procesarImagen(ruta, guardar=True, dimensionLimite=dimensionLimite)

    originalRGB = cv2.cvtColor(original, cv2.COLOR_BGR2RGB)
    documentoFinalRGB = cv2.cvtColor(documentoFinal, cv2.COLOR_BGR2RGB)

    plt.figure(figsize=(14, 7))

    plt.subplot(1, 2, 1)
    plt.imshow(originalRGB)
    plt.title("Antes (foto original)")
    plt.axis("off")

    plt.subplot(1, 2, 2)
    plt.imshow(documentoFinalRGB)
    plt.title("Después (enderezado)")
    plt.axis("off")

    plt.tight_layout()
    plt.savefig("comparacion_antes_despues.png", dpi=150)
    print("Comparación guardada en: comparacion_antes_despues.png")

    plt.show()


if __name__ == "__main__":
    ruta = sys.argv[1] if len(sys.argv) > 1 else "imagenes/imagen8.jpg"
    mostrarAntesDespues(ruta)