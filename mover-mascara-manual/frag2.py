import ipywidgets as widgets
import cv2
import numpy as np
import matplotlib.pyplot as plt
import os
import sys
from IPython.display import display, clear_output

# Definición defensiva de cargarImagen si no existe en el entorno
if 'cargarImagen' not in globals():
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

# Definición defensiva de la ruta de imagen si no está definida
if 'rutaImagen' not in globals() or not os.path.exists(globals().get('rutaImagen', '')):
    rutaImagen = "h2.png"

def detectarBordesYEsquinas_interactivo(original, gris, umbral_factor):
    imagenMarcada = original.copy()

    filtroBorde = cv2.GaussianBlur(gris, (1, 1), 0)
    filtroEsquina = cv2.GaussianBlur(gris, (11, 11), 0)

    bordes = cv2.Canny(filtroBorde, 120, 200)
    esquina_entrada = np.float32(filtroEsquina)

    esquina = cv2.cornerHarris(esquina_entrada, 14, 5, 0.05)
    esquina = cv2.dilate(esquina, None)

    # Usamos el umbral_factor del slider
    umbral = umbral_factor * esquina.max()
    imagenMarcada[esquina > umbral] = [0, 0, 255] # Rojo en formato BGR

    return bordes, imagenMarcada

def procesarImagen_interactivo(umbral_factor):
    clear_output(wait=True) # Limpia la salida anterior antes de mostrar la nueva figura

    original = cargarImagen(rutaImagen) # Reutiliza la función cargarImagen
    gris = cv2.cvtColor(original, cv2.COLOR_BGR2GRAY)

    # No necesitamos la segmentación para este ajuste interactivo, pero podríamos incluirla si fuera necesario.
    # umbralBasico, umbralOtsu, valorUmbral, umbralCalculado = segmentarImagen(gris)

    bordes, imagenMarcada = detectarBordesYEsquinas_interactivo(original, gris, umbral_factor)

    originalRGB = cv2.cvtColor(original, cv2.COLOR_BGR2RGB)
    imagenMarcadaRGB = cv2.cvtColor(imagenMarcada, cv2.COLOR_BGR2RGB)

    plt.figure(figsize=(10, 5))
    plt.subplot(1, 2, 1)
    plt.imshow(originalRGB)
    plt.title("Imagen Original")
    plt.axis("off")

    plt.subplot(1, 2, 2)
    plt.imshow(imagenMarcadaRGB)
    plt.title(f"Esquinas Harris (Umbral: {umbral_factor:.2f} * max)")
    plt.axis("off")

    plt.tight_layout()
    plt.show()

# Crear un slider para el umbral_factor
umbral_slider = widgets.FloatSlider(
    value=0.20, # Valor inicial, el último que usamos
    min=0.01,   # Valor mínimo del umbral_factor
    max=0.50,   # Valor máximo del umbral_factor
    step=0.01,  # Incremento del deslizador
    description='Umbral Factor:',
    continuous_update=True # Actualizar mientras se arrastra
)

# Mostrar el widget interactivo
interactive_plot = widgets.interactive(procesarImagen_interactivo, umbral_factor=umbral_slider)
display(interactive_plot)
