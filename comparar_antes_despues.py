"""
comparar_antes_despues.py

Script independiente: corre el pipeline completo de procesador_documento.py
sobre una foto y muestra una comparación lado a lado de:
  - Antes: la foto original tal cual se cargó.
  - Después: el documento ya enderezado/recortado (perspective transform).

También guarda la comparación como imagen (comparacion_antes_despues.png)
por si quieres revisarla después o mandarla a alguien.

Uso:
    python comparar_antes_despues.py ruta_de_la_foto.jpg
"""

import cv2
import matplotlib.pyplot as plt
import sys
from procesador_documento import procesarImagen, cargarImagen


def mostrarAntesDespues(ruta, dimensionLimite=1080):
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
    ruta = sys.argv[1] if len(sys.argv) > 1 else "imagenes/IMG_20260704_150429.jpg"
    mostrarAntesDespues(ruta)
