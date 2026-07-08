import cv2
import numpy as np

# =======================================================================
# NÚCLEO GEOMÉTRICO (Algoritmo Monotone Chain)
# =======================================================================


def cross_product(p1: tuple, p2: tuple, p3: tuple) -> float:
    return (p2[0] - p1[0]) * (p3[1] - p1[1]) - (p2[1] - p1[1]) * (p3[0] - p1[0])


def compute_convex_hull(points: list[tuple[int, int]]) -> list[tuple[int, int]]:
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


# =======================================================================
# PIPELINE DE DIBUJO DE CONTORNO
# =======================================================================


def overlay_convex_hull_contour(
    image: np.ndarray,
    raw_coordinates: list[tuple[int, int]],
    color: tuple[int, int, int] = (0, 0, 255),
    thickness: int = 2,
) -> np.ndarray:
    """Calcula el casco convexo a partir de coordenadas (h, w) y dibuja su

    contorno sobre la imagen.

    :param image: Imagen original (Matriz NumPy)
    :param raw_coordinates: Lista de tuplas en formato (h, w)
    :param color: Color del trazo en formato BGR (Por defecto: Rojo)
    :param thickness: Grosor de la línea en píxeles
    :return: Una nueva imagen con el contorno superpuesto
    """
    # 1. Copiar la imagen para no destruir el canvas original (Buena práctica)
    output_image = image.copy()

    # 2. Inversión crítica de ejes: de (h, w) a (w, h) para mapeo espacial X, Y
    spatial_points = [(w, h) for (h, w) in raw_coordinates]

    # 3. Calcular el casco convexo con tu algoritmo nativo
    hull_spatial = compute_convex_hull(spatial_points)

    # 4. Formatear los puntos al estándar que exige OpenCV para polígonos (int32)
    opencv_hull = np.array(hull_spatial, dtype=np.int32).reshape((-1, 1, 2))

    # 5. Dibujar el contorno exterior
    # isClosed=True asegura que el último punto se conecte automáticamente con el primero
    cv2.polylines(
        output_image, [opencv_hull], isClosed=True, color=color, thickness=thickness
    )

    return output_image


# =======================================================================
# PRUEBA DE EJECUCIÓN EN TERMINAL
# =======================================================================
if __name__ == "__main__":
    print("[*] Creando lienzo e inyectando ecuación...")

    # Generamos una imagen base (Gris oscuro, 300x400 píxeles, 3 canales BGR)
    imagen_base = np.full((300, 400, 3), 50, dtype=np.uint8)

    # Añadimos texto simulando la ecuación matemática original
    cv2.putText(
        imagen_base,
        "f(x) = x^2",
        (110, 160),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.0,
        (0, 255, 0),
        2,
    )

    # Coordenadas crudas dispersas recibidas en formato (h, w)
    coordenadas_h_w = [
        (80, 80),
        (80, 320),
        (220, 340),
        (220, 60),  # Esquinas exteriores
        (80, 200),
        (150, 330),
        (220, 200),
        (150, 70),  # Bordes
        (150, 200),
        (160, 210),  # Ruido interno de la ecuación
    ]

    print("[+] Procesando y superponiendo el contorno del Casco Convexo...")

    # Llamamos a la función para pintar una línea ROJA (0, 0, 255) de 2px de grosor
    imagen_con_contorno = overlay_convex_hull_contour(
        imagen_base, coordenadas_h_w, color=(0, 0, 255), thickness=2
    )

    # Guardar el resultado para validación visual
    archivo_salida = "tolatex_contorno_hull.png"
    cv2.imwrite(archivo_salida, imagen_con_contorno)

    print(f"\n[✓] ¡Listo! Archivo '{archivo_salida}' generado.")
    print(
        "    Abre la imagen para verificar la línea roja perimetral sobrepuesta."
    )