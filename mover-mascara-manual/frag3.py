import os
import ipywidgets as widgets
from IPython.display import display, clear_output
import cv2
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.widgets import RectangleSelector

# Definición defensiva de cargarImagen si no existe en el entorno
if 'cargarImagen' not in globals():
    def cargarImagen(ruta):
        """Carga la imagen en color desde el disco utilizando OpenCV."""
        if not os.path.exists(ruta):
            raise FileNotFoundError(f"No se pudo encontrar la imagen en la ruta: '{ruta}'")
        imagen = cv2.imread(ruta)
        if imagen is None:
            raise ValueError(f"No se pudo cargar la imagen desde: '{ruta}'")
        return imagen

# Definición defensiva de la ruta de imagen si no está definida
if 'rutaImagen' not in globals() or not os.path.exists(globals().get('rutaImagen', '')):
    if os.path.exists("h2.png"):
        rutaImagen = "h2.png"
    elif os.path.exists("imagen.jpg"):
        rutaImagen = "imagen.jpg"
    else:
        rutaImagen = "h2.png"

# Variables globales para que las celdas posteriores del notebook puedan usarlas
coordenadas_roi_globales = None
imagen_roi_global = None

class SelectorROIManual:
    """Selección interactiva con el ratón: arrastra el rectángulo rojo o sus esquinas directamente sobre la imagen sin sliders."""
    def __init__(self, ruta_imagen=None):
        self.ruta_imagen = ruta_imagen or globals().get('rutaImagen', 'h2.png')
        self.imagen_original = cargarImagen(self.ruta_imagen)
        self.imagen_original_rgb = cv2.cvtColor(self.imagen_original, cv2.COLOR_BGR2RGB)
        self.altura_imagen, self.ancho_imagen, _ = self.imagen_original_rgb.shape

        self.coords = [0, 0, self.ancho_imagen, self.altura_imagen]

        print("Haz clic y arrastra con el ratón directamente sobre la imagen para definir o mover el rectángulo rojo y sus esquinas.")

        # Crear figura interactiva de Matplotlib
        self.fig, self.ax = plt.subplots(figsize=(9, 7))
        self.ax.imshow(self.imagen_original_rgb)
        self.ax.set_title("Arrastra con el ratón para mover el rectángulo rojo / esquinas")
        self.ax.axis("off")

        # RectangleSelector permite:
        # 1. Hacer clic y arrastrar para crear/mover el rectángulo rojo.
        # 2. Arrastrar sus esquinas (interactive=True).
        # 3. Arrastrar el rectángulo completo desde el centro (drag_from_anywhere=True).
        self.selector = RectangleSelector(
            self.ax,
            self.al_seleccionar,
            useblit=True,
            button=[1],  # Clic izquierdo
            minspanx=5,
            minspany=5,
            interactive=True,
            drag_from_anywhere=True,
            props=dict(facecolor='none', edgecolor='red', linewidth=3)
        )

        # Botón para confirmar el recorte
        self.boton_confirmar = widgets.Button(
            description="Confirmar Recorte RI",
            button_style='danger',
            icon='crop'
        )
        self.salida_final = widgets.Output()
        self.boton_confirmar.on_click(self.confirmar_recorte)

    def al_seleccionar(self, eclick, erelease):
        """Se ejecuta automáticamente cuando mueves el rectángulo rojo o sus esquinas con el ratón."""
        x1, y1 = int(eclick.xdata), int(eclick.ydata)
        x2, y2 = int(erelease.xdata), int(erelease.ydata)

        x_min, x_max = max(0, min(x1, x2)), min(self.ancho_imagen, max(x1, x2))
        y_min, y_max = max(0, min(y1, y2)), min(self.altura_imagen, max(y1, y2))

        w = x_max - x_min
        h = y_max - y_min

        self.coords = [x_min, y_min, w, h]
        self.ax.set_title(f"Rectángulo Rojo RI: (X={x_min}, Y={y_min}, Ancho={w}px, Alto={h}px)")
        self.fig.canvas.draw_idle()

    def confirmar_recorte(self, _):
        global coordenadas_roi_globales, imagen_roi_global

        x, y, w, h = self.coords
        with self.salida_final:
            clear_output(wait=True)
            if w > 0 and h > 0:
                coordenadas_roi_globales = (x, y, w, h)
                imagen_roi_global = self.imagen_original_rgb[y:y+h, x:x+w]

                print("✓ Región de Interés recortada correctamente con el ratón!")
                print(f"  Coordenadas (x, y, ancho, alto) = {coordenadas_roi_globales}")

                fig, ax = plt.subplots(figsize=(6, 6))
                ax.imshow(imagen_roi_global)
                ax.set_title("Región de Interés (RI) Final Recortada")
                ax.axis("off")
                plt.show()
                plt.close(fig)
            else:
                print("Error: Selecciona una región válida arrastrando con el ratón.")

    def mostrar(self):
        plt.show()
        display(self.boton_confirmar)
        display(self.salida_final)

def seleccionar_roi_opencv(ruta=None):
    """Función alternativa usando la ventana nativa interactiva de OpenCV (cv2.selectROI) sin sliders."""
    global coordenadas_roi_globales, imagen_roi_global
    ruta_img = ruta or globals().get('rutaImagen', 'h2.png')
    img = cv2.imread(ruta_img)
    if img is None:
        print("Error al cargar la imagen.")
        return

    # Ventana nativa de selección con el ratón de OpenCV
    rect = cv2.selectROI("Selecciona la Región de Interés con el Ratón (Presiona ENTER o ESPACIO para confirmar)", img, showCrosshair=True)
    cv2.destroyAllWindows()

    x, y, w, h = rect
    if w > 0 and h > 0:
        coordenadas_roi_globales = (x, y, w, h)
        img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        imagen_roi_global = img_rgb[y:y+h, x:x+w]
        print(f"✓ ROI Seleccionada con OpenCV: {coordenadas_roi_globales}")
        return imagen_roi_global
    else:
        print("Selección cancelada.")

# Instanciar el selector interactivo con ratón (sin sliders)
selector_roi = SelectorROIManual(rutaImagen)
selector_roi.mostrar()