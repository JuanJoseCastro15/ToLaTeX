import cv2
import numpy as np
import matplotlib.pyplot as plt
import sys
import os


def cargarImagen(ruta):
    """Carga la imagen en color y valida que exista."""
    if not os.path.exists(ruta):
        print(f"Error: La ruta '{ruta}' no existe.")
        sys.exit(1)

    original = cv2.imread(ruta)
    if original is None:
        print(f"Error: No se pudo cargar la imagen en la ruta '{ruta}'")
        sys.exit(1)

    return original


def segmentarImagen(gris):
    """Aplica umbral básico y umbral de Otsu sobre la imagen en grises."""
    valorUmbral = 127
    _, umbralBasico = cv2.threshold(gris, valorUmbral, 255, cv2.THRESH_BINARY)

    umbralCalculado, umbralOtsu = cv2.threshold(
        gris, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    print(f"El umbral óptimo calculado por Otsu es: {umbralCalculado}")

    return umbralBasico, umbralOtsu, valorUmbral, umbralCalculado


def detectarBordesYEsquinas(original, gris):
    """Detecta bordes con Canny y esquinas con Harris, marcando las esquinas en rojo."""
    imagenMarcada = original.copy()

    filtroBorde = cv2.GaussianBlur(gris, (1, 1), 0)
    filtroEsquina = cv2.GaussianBlur(gris, (11, 11), 0)

    bordes = cv2.Canny(filtroBorde, 120, 200)

    espacioEsquina = cv2.Canny(filtroEsquina, 30, 150)
    espacioEsquina = np.float32(espacioEsquina)

    esquina = cv2.cornerHarris(espacioEsquina, 14, 5, 0.04)
    esquina = cv2.dilate(esquina, None)

    umbral = 0.33 * esquina.max()
    imagenMarcada[esquina > umbral] = [0, 0, 255]  # Rojo en formato BGR

    return bordes, imagenMarcada


def procesarImagen(ruta):
    """Pipeline completo: segmentación + bordes/esquinas, todo en una sola figura."""
    original = cargarImagen(ruta)
    gris = cv2.cvtColor(original, cv2.COLOR_BGR2GRAY)

    # --- Segmentación ---
    umbralBasico, umbralOtsu, valorUmbral, umbralCalculado = segmentarImagen(gris)

    # --- Bordes y esquinas ---
    bordes, imagenMarcada = detectarBordesYEsquinas(original, gris)

    # Convertir BGR -> RGB para que matplotlib muestre los colores correctamente
    originalRGB = cv2.cvtColor(original, cv2.COLOR_BGR2RGB)
    imagenMarcadaRGB = cv2.cvtColor(imagenMarcada, cv2.COLOR_BGR2RGB)

    # --- Mostrar todo en una sola figura con 6 subplots ---
    titulos = [
        "Imagen Original",
        f"Umbral Básico (T={valorUmbral})",
        f"Umbral de Otsu (T={umbralCalculado})",
        "Escala de Grises",
        "Detector de Bordes (Canny)",
        "Detector de Esquinas (Harris)",
    ]
    imagenes = [originalRGB, umbralBasico, umbralOtsu, gris, bordes, imagenMarcadaRGB]
    mapasColor = [None, "gray", "gray", "gray", "gray", None]

    plt.figure(figsize=(15, 8))
    for i in range(6):
        plt.subplot(2, 3, i + 1)
        plt.imshow(imagenes[i], cmap=mapasColor[i])
        plt.title(titulos[i])
        plt.axis("off")

    plt.tight_layout()
    plt.show(block=True)


# --- EJECUCIÓN ---
if __name__ == "__main__":
    # Si se pasa la ruta como argumento por consola, se usa esa.
    # Si no, usa '01_image.jpg' por defecto.
    rutaImagen = sys.argv[1] if len(sys.argv) > 1 else "01_image.jpg"
    procesarImagen(rutaImagen)