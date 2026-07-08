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


def detectarBordesYEsquinas(original, gris):
    imagenMarcada = original.copy()

    filtroBorde   = cv2.GaussianBlur(gris, (1, 1),   0)
    filtroEsquina = cv2.GaussianBlur(gris, (11, 11), 0)

    bordes = cv2.Canny(filtroBorde, 120, 200)

    espacioEsquina = cv2.Canny(filtroEsquina, 30, 150)
    espacioEsquina = np.float32(espacioEsquina)

    esquina = cv2.cornerHarris(espacioEsquina, 14, 5, 0.04)
    esquina = cv2.dilate(esquina, None)

    umbral = 0.33 * esquina.max()
    imagenMarcada[esquina > umbral] = [0, 0, 255]

    # ── GUARDAR COORDENADAS (h, w) ───────────────────────────────────────
    filas, columnas = np.where(esquina > umbral)
    coordenadas = list(zip(filas.tolist(), columnas.tolist()))

    with open("coordenadas_esquinas.txt", "w") as archivo:
        archivo.write("# Coordenadas de esquinas detectadas\n")
        archivo.write("# Formato: h (altura), w (anchura)\n")
        archivo.write(f"# Total: {len(coordenadas)}\n")
        for h, w in coordenadas:
            archivo.write(f"{h},{w}\n")

    print(f"Esquinas detectadas: {len(coordenadas)}")
    print("Coordenadas guardadas en: coordenadas_esquinas.txt")
    # ─────────────────────────────────────────────────────────────────────

    return bordes, imagenMarcada, coordenadas  # 👈 Retorna las coordenadas también


def procesarImagen(ruta):
    original = cargarImagen(ruta)
    gris = cv2.cvtColor(original, cv2.COLOR_BGR2GRAY)

    umbralBasico, umbralOtsu, valorUmbral, umbralCalculado = segmentarImagen(gris)

    bordes, imagenMarcada, coordenadas = detectarBordesYEsquinas(original, gris)  # 👈

    originalRGB      = cv2.cvtColor(original,      cv2.COLOR_BGR2RGB)
    imagenMarcadaRGB = cv2.cvtColor(imagenMarcada, cv2.COLOR_BGR2RGB)

    titulos = [
        "Imagen Original",
        f"Umbral Básico (T={valorUmbral})",
        f"Umbral de Otsu (T={umbralCalculado})",
        "Escala de Grises",
        "Detector de Bordes (Canny)",
        "Detector de Esquinas (Harris)",
    ]
    imagenes   = [originalRGB, umbralBasico, umbralOtsu, gris, bordes, imagenMarcadaRGB]
    mapasColor = [None, "gray", "gray", "gray", "gray", None]

    plt.figure(figsize=(15, 8))
    for i in range(6):
        plt.subplot(2, 3, i + 1)
        plt.imshow(imagenes[i], cmap=mapasColor[i])
        plt.title(titulos[i])
        plt.axis("off")

    plt.tight_layout()
    plt.show(block=True)

    return coordenadas


# --- EJECUCIÓN ---
if __name__ == "__main__":
    rutaImagen = sys.argv[1] if len(sys.argv) > 1 else "IMG_20260704_150429.jpg"
    procesarImagen(rutaImagen)