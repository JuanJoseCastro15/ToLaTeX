"""
seleccion_manual.py

Toma la imagen ya recortada/enderezada (salida del procesador_documento)
y permite al usuario seleccionar manualmente VARIAS áreas con el mouse
antes de confirmar:

  - Click izquierdo + arrastrar sobre la imagen -> dibuja un rectángulo
    de selección. Al soltar el click, ese rectángulo queda guardado y
    puedes dibujar otro inmediatamente.
  - Click sobre el botón verde "CONFIRMAR (N)" (debajo de la imagen) ->
    recorta TODAS las áreas seleccionadas.
  - Tecla 'z'   -> deshace el último rectángulo dibujado.
  - Tecla 'r'   -> reinicia (borra todos los rectángulos).
  - Tecla 'q' / ESC -> cierra el programa sin recortar.

Uso:
    python seleccion_manual.py ruta_de_la_foto_original.jpg
"""

import cv2
import numpy as np
import sys
from procesador_documento import procesarImagen

VENTANA = "Selecciona una o mas areas y confirma con el boton verde"

ALTO_BOTON = 60          # alto del panel del botón, en píxeles
MARGEN_BOTON = 15        # separación del botón respecto a los bordes

MAX_ANCHO_VENTANA = 1000  # tamaño máximo de la ventana en pantalla
MAX_ALTO_VENTANA = 700

# Estado global de la selección
punto_inicio = None
punto_actual = None
seleccionando = False
rectangulos = []               # lista de (x1, y1, x2, y2) ya confirmados con el mouse
rectangulos_finales = None     # lista final (en coords originales) cuando se da CONFIRMAR
boton_rect = None              # (bx1, by1, bx2, by2) coordenadas del botón
confirmar_click = False        # bandera: se dio click en el botón


def click_mouse(event, x, y, flags, param):
    global punto_inicio, punto_actual, seleccionando, confirmar_click

    alto_imagen = param["alto_imagen"]
    ancho_imagen = param["ancho_imagen"]

    if event == cv2.EVENT_LBUTTONDOWN:
        if y < alto_imagen:
            # Click dentro del área de la imagen -> empieza un nuevo rectángulo
            punto_inicio = (x, y)
            punto_actual = (x, y)
            seleccionando = True
        else:
            # Click dentro del panel del botón
            bx1, by1, bx2, by2 = boton_rect
            if bx1 <= x <= bx2 and by1 <= y <= by2:
                confirmar_click = True

    elif event == cv2.EVENT_MOUSEMOVE:
        if seleccionando:
            x = max(0, min(x, ancho_imagen - 1))
            y = max(0, min(y, alto_imagen - 1))
            punto_actual = (x, y)

    elif event == cv2.EVENT_LBUTTONUP:
        if seleccionando:
            x = max(0, min(x, ancho_imagen - 1))
            y = max(0, min(y, alto_imagen - 1))
            punto_actual = (x, y)

            x1, y1, x2, y2 = normalizar_rectangulo(punto_inicio, punto_actual)
            if x2 - x1 > 2 and y2 - y1 > 2:
                rectangulos.append((x1, y1, x2, y2))

            punto_inicio = None
            punto_actual = None
        seleccionando = False


def normalizar_rectangulo(p1, p2):
    x1, y1 = p1
    x2, y2 = p2
    return min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)


def construir_lienzo(imagen, cantidad_rects):
    """
    Arma la imagen final que se muestra: la foto arriba + un panel
    gris abajo con el botón verde "CONFIRMAR (N)".
    """
    global boton_rect

    alto, ancho = imagen.shape[:2]
    panel = np.full((ALTO_BOTON, ancho, 3), 230, dtype=np.uint8)  # gris claro

    ancho_boton = min(240, ancho - 2 * MARGEN_BOTON)
    bx1 = (ancho - ancho_boton) // 2
    by1 = MARGEN_BOTON // 2
    bx2 = bx1 + ancho_boton
    by2 = ALTO_BOTON - MARGEN_BOTON // 2

    hay_seleccion = cantidad_rects > 0
    color_boton = (0, 200, 0) if hay_seleccion else (170, 170, 170)
    cv2.rectangle(panel, (bx1, by1), (bx2, by2), color_boton, -1)
    cv2.rectangle(panel, (bx1, by1), (bx2, by2), (0, 0, 0), 2)

    texto = f"CONFIRMAR ({cantidad_rects})" if hay_seleccion else "CONFIRMAR"
    (tw, th), _ = cv2.getTextSize(texto, cv2.FONT_HERSHEY_SIMPLEX, 0.65, 2)
    tx = bx1 + (ancho_boton - tw) // 2
    ty = by1 + (by2 - by1 + th) // 2
    cv2.putText(panel, texto, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.65,
                (255, 255, 255), 2, cv2.LINE_AA)

    boton_rect = (bx1, by1 + alto, bx2, by2 + alto)

    lienzo = np.vstack([imagen, panel])
    return lienzo


def seleccionar_areas(imagen):
    """
    Muestra la imagen y deja que el usuario dibuje varios rectángulos.
    Regresa una lista de sub-imágenes recortadas (en resolución original),
    o una lista vacía si el usuario cierra sin confirmar nada.
    """
    global punto_inicio, punto_actual, rectangulos, rectangulos_finales, confirmar_click

    alto_original, ancho_original = imagen.shape[:2]

    escala = min(
        MAX_ANCHO_VENTANA / ancho_original,
        MAX_ALTO_VENTANA / alto_original,
        1.0,
    )
    ancho = int(ancho_original * escala)
    alto = int(alto_original * escala)
    imagen_escalada = cv2.resize(imagen, (ancho, alto), interpolation=cv2.INTER_AREA)

    cv2.namedWindow(VENTANA)
    cv2.setMouseCallback(
        VENTANA, click_mouse,
        param={"alto_imagen": alto, "ancho_imagen": ancho}
    )

    while True:
        vista = imagen_escalada.copy()

        # Dibujamos todos los rectángulos ya confirmados con el mouse
        for i, (x1, y1, x2, y2) in enumerate(rectangulos, start=1):
            cv2.rectangle(vista, (x1, y1), (x2, y2), (0, 255, 0), 2)
            cv2.putText(vista, str(i), (x1 + 4, y1 + 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2, cv2.LINE_AA)

        # Rectángulo que se está dibujando ahora mismo (aún no soltado)
        if punto_inicio is not None and punto_actual is not None:
            cv2.rectangle(vista, punto_inicio, punto_actual, (0, 255, 255), 2)

        cv2.putText(
            vista, "Arrastra para agregar areas | 'z'=deshacer 'r'=reset 'q'=salir",
            (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2, cv2.LINE_AA
        )

        lienzo = construir_lienzo(vista, len(rectangulos))
        cv2.imshow(VENTANA, lienzo)
        tecla = cv2.waitKey(20) & 0xFF

        if confirmar_click:
            confirmar_click = False
            if len(rectangulos) > 0:
                rectangulos_finales = list(rectangulos)
                break
            else:
                print("Primero dibuja al menos un área antes de confirmar.")

        if tecla == ord('z'):
            if rectangulos:
                rectangulos.pop()

        elif tecla == ord('r'):
            rectangulos.clear()
            punto_inicio = None
            punto_actual = None

        elif tecla == ord('q') or tecla == 27:  # 27 = ESC
            rectangulos_finales = None
            break

    cv2.destroyWindow(VENTANA)

    if not rectangulos_finales:
        return []

    # Convertimos cada rectángulo de coords de la vista escalada a
    # coords de la imagen original, y recortamos ahí para conservar calidad.
    recortes = []
    for (x1, y1, x2, y2) in rectangulos_finales:
        ox1 = max(0, min(int(x1 / escala), ancho_original))
        oy1 = max(0, min(int(y1 / escala), alto_original))
        ox2 = max(0, min(int(x2 / escala), ancho_original))
        oy2 = max(0, min(int(y2 / escala), alto_original))
        recortes.append(imagen[oy1:oy2, ox1:ox2])

    return recortes


if __name__ == "__main__":
    ruta = sys.argv[1] if len(sys.argv) > 1 else "imagenes/IMG_20260704_150429.jpg"

    # 1) Obtenemos la imagen ya recortada/enderezada del documento
    documento = procesarImagen(ruta)

    # 2) Selección manual de una o varias áreas, con botón verde
    recortes = seleccionar_areas(documento)

    if recortes:
        for i, recorte in enumerate(recortes, start=1):
            if recorte.size == 0:
                continue
            nombre = f"recorte_final_{i}.png"
            cv2.imwrite(nombre, recorte)
            print(f"Guardado: {nombre}")
            cv2.imshow(f"Recorte {i}", recorte)

        print(f"{len(recortes)} recorte(s) guardado(s). Presiona cualquier tecla para cerrar.")
        cv2.waitKey(0)
        cv2.destroyAllWindows()
    else:
        print("No se confirmó ninguna selección. Programa finalizado.")