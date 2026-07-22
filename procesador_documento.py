"""
procesador_documento.py

Contiene únicamente las funciones responsables de:
  1) Recibir/cargar la imagen.
  2) Detectar el documento dentro de la foto.
  3) Enderezarlo y recortarlo (perspective transform).

Es el mismo pipeline del script original, solo que sin la parte de
visualización con matplotlib, para poder importarlo desde otro programa.
"""

import cv2
import numpy as np
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


def detectarEsquinas(original, bordes):
    imagenMarcada = original.copy()

    contornos, _ = cv2.findContours(
        bordes, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE
    )

    if len(contornos) == 0:
        print("No se detectaron contornos. Se usa la imagen original sin marcar.")
        return imagenMarcada, []

    candidatos = sorted(contornos, key=cv2.contourArea, reverse=True)[:5]
    candidatosHull = [contornoAConvexHull(c) for c in candidatos]

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
        print("No se encontró un contorno con exactamente 4 esquinas.")
        return imagenMarcada, []

    puntos = np.concatenate(esquinas).tolist()
    puntos = ordenarPuntos(puntos)

    return imagenMarcada, puntos


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


def procesarImagen(ruta, guardar=True):
    """
    Pipeline completo: recibe la ruta de la foto original y regresa
    la imagen del documento ya enderezado/recortado (documentoFinal).
    Si no se detectan las 4 esquinas, regresa la imagen original tal cual.
    """
    original = cargarImagen(ruta)

    imagenLimpia = limpiarTexto(original, tamanoKernel=5, iteraciones=3)
    imagenSinFondo, _ = quitarFondo(imagenLimpia, margen=20, iteraciones=5)
    grisFinal = cv2.cvtColor(imagenSinFondo, cv2.COLOR_BGR2GRAY)
    bordes = detectarBordes(grisFinal)
    _, esquinas = detectarEsquinas(original, bordes)

    if len(esquinas) == 4:
        destino = encontrarDestino(esquinas)
        documentoFinal = enderezarDocumento(original, esquinas, destino)
        print("Documento detectado y enderezado correctamente.")
    else:
        print("No se detectaron las 4 esquinas; se usa la imagen original.")
        documentoFinal = original.copy()

    if guardar:
        cv2.imwrite("documento_enderezado.png", documentoFinal)
        print("Guardado como: documento_enderezado.png")

    return documentoFinal
