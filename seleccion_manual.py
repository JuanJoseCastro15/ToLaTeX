"""
seleccion_manual.py

Toma la imagen ya recortada/enderezada (salida del procesador_documento)
y permite al usuario seleccionar manualmente un área con el mouse:

  - Click izquierdo + arrastrar sobre la imagen -> dibuja un rectángulo
    de selección.
  - Click sobre el botón verde "CONFIRMAR" (debajo de la imagen) ->
    recorta el área seleccionada.
  - Tecla 'r'   -> reinicia la selección.
  - Tecla 'q' / ESC -> cierra el programa sin recortar.

Uso:
    python seleccion_manual.py ruta_de_la_foto_original.jpg
"""

import cv2
import numpy as np
import sys
from procesador_documento import procesarImagen

VENTANA = "Selecciona un area y confirma con el boton verde"

ALTO_BOTON = 60          # alto del panel del botón, en píxeles
MARGEN_BOTON = 15        # separación del botón respecto a los bordes

MAX_ANCHO_VENTANA = 1000  # tamaño máximo de la ventana en pantalla
MAX_ALTO_VENTANA = 700

# Estado global de la selección
punto_inicio = None
punto_actual = None
seleccionando = False
rectangulo_confirmado = None  # (x1, y1, x2, y2) cuando ya se confirmó
boton_rect = None             # (bx1, by1, bx2, by2) coordenadas del botón
confirmar_click = False       # bandera: se dio click en el botón


def click_mouse(event, x, y, flags, param):
    global punto_inicio, punto_actual, seleccionando, confirmar_click

    alto_imagen = param["alto_imagen"]
    ancho_imagen = param["ancho_imagen"]

    if event == cv2.EVENT_LBUTTONDOWN:
        if y < alto_imagen:
            # Click dentro del área de la imagen -> empieza selección
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
            # Limitamos el arrastre para que no se salga de la imagen
            x = max(0, min(x, ancho_imagen - 1))
            y = max(0, min(y, alto_imagen - 1))
            punto_actual = (x, y)

    elif event == cv2.EVENT_LBUTTONUP:
        if seleccionando:
            x = max(0, min(x, ancho_imagen - 1))
            y = max(0, min(y, alto_imagen - 1))
            punto_actual = (x, y)
        seleccionando = False


def normalizar_rectangulo(p1, p2):
    x1, y1 = p1
    x2, y2 = p2
    return min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)


def construir_lienzo(imagen, hay_seleccion):
    """
    Arma la imagen final que se muestra: la foto arriba + un panel
    gris abajo con el botón verde "CONFIRMAR".
    """
    global boton_rect

    alto, ancho = imagen.shape[:2]
    panel = np.full((ALTO_BOTON, ancho, 3), 230, dtype=np.uint8)  # gris claro

    ancho_boton = min(220, ancho - 2 * MARGEN_BOTON)
    bx1 = (ancho - ancho_boton) // 2
    by1 = MARGEN_BOTON // 2
    bx2 = bx1 + ancho_boton
    by2 = ALTO_BOTON - MARGEN_BOTON // 2

    # El botón cambia de color según si ya hay una selección dibujada,
    # para que el usuario sepa de un vistazo si puede confirmar.
    color_boton = (0, 200, 0) if hay_seleccion else (170, 170, 170)
    cv2.rectangle(panel, (bx1, by1), (bx2, by2), color_boton, -1)
    cv2.rectangle(panel, (bx1, by1), (bx2, by2), (0, 0, 0), 2)

    texto = "CONFIRMAR"
    (tw, th), _ = cv2.getTextSize(texto, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
    tx = bx1 + (ancho_boton - tw) // 2
    ty = by1 + (by2 - by1 + th) // 2
    cv2.putText(panel, texto, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (255, 255, 255), 2, cv2.LINE_AA)

    # Guardamos las coordenadas del botón en el sistema de coordenadas
    # del lienzo completo (imagen + panel), por eso sumamos "alto".
    boton_rect = (bx1, by1 + alto, bx2, by2 + alto)

    lienzo = np.vstack([imagen, panel])
    return lienzo


def seleccionar_area(imagen):
    global punto_inicio, punto_actual, rectangulo_confirmado, confirmar_click

    alto_original, ancho_original = imagen.shape[:2]

    # Calculamos un factor de escala para que la ventana no sea más
    # grande que MAX_ANCHO_VENTANA x MAX_ALTO_VENTANA. Si la imagen ya
    # es más chica que eso, no la agrandamos (escala máxima = 1.0).
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
        hay_seleccion = punto_inicio is not None and punto_actual is not None

        if hay_seleccion:
            cv2.rectangle(vista, punto_inicio, punto_actual, (0, 255, 0), 2)

        cv2.putText(
            vista, "Arrastra para seleccionar | 'r'=reset  'q'=salir",
            (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2, cv2.LINE_AA
        )

        lienzo = construir_lienzo(vista, hay_seleccion)
        cv2.imshow(VENTANA, lienzo)
        tecla = cv2.waitKey(20) & 0xFF

        if confirmar_click:
            confirmar_click = False
            if hay_seleccion:
                x1, y1, x2, y2 = normalizar_rectangulo(punto_inicio, punto_actual)
                if x2 - x1 > 2 and y2 - y1 > 2:
                    rectangulo_confirmado = (x1, y1, x2, y2)
                    break
                else:
                    print("La selección es muy pequeña, intenta de nuevo.")
            else:
                print("Primero dibuja un área con el mouse antes de confirmar.")

        if tecla == ord('r'):
            punto_inicio = None
            punto_actual = None

        elif tecla == ord('q') or tecla == 27:  # 27 = ESC
            rectangulo_confirmado = None
            break

    cv2.destroyWindow(VENTANA)

    if rectangulo_confirmado is None:
        return None

    # Las coordenadas se dibujaron sobre la imagen escalada; las
    # convertimos de vuelta a la resolución original antes de recortar,
    # así el recorte final conserva la calidad completa de la foto.
    x1, y1, x2, y2 = rectangulo_confirmado
    x1 = int(x1 / escala)
    y1 = int(y1 / escala)
    x2 = int(x2 / escala)
    y2 = int(y2 / escala)

    x1 = max(0, min(x1, ancho_original))
    x2 = max(0, min(x2, ancho_original))
    y1 = max(0, min(y1, alto_original))
    y2 = max(0, min(y2, alto_original))

    recorte = imagen[y1:y2, x1:x2]
    return recorte


if __name__ == "__main__":
    ruta = sys.argv[1] if len(sys.argv) > 1 else "imagenes/IMG_20260704_150429.jpg"

    # 1) Obtenemos la imagen ya recortada/enderezada del documento
    documento = procesarImagen(ruta)

    # 2) Selección manual sobre esa imagen ya recortada, con botón verde
    recorteFinal = seleccionar_area(documento)

    if recorteFinal is not None and recorteFinal.size > 0:
        cv2.imwrite("recorte_final.png", recorteFinal)
        print("Recorte final guardado en: recorte_final.png")

        cv2.imshow("Recorte final", recorteFinal)
        print("Presiona cualquier tecla sobre la ventana para cerrar.")
        cv2.waitKey(0)
        cv2.destroyAllWindows()
    else:
        print("No se confirmó ninguna selección. Programa finalizado.")