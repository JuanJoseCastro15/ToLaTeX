import cv2
import matplotlib.pyplot as plt

def segmentarImagen(ruta):
    #esta funcion es para hacer toda la imagen gris
    imagen = cv2.imread(ruta, cv2.IMREAD_GRAYSCALE)

    #validacion por si acaso no se cargo la foto
    if imagen is None:
        print(f"Error: No se pudo cargar la imagen en la ruta '{ruta}'")
        return

    #valor basico del umbral
    valorUmbral = 127
    #separar imagen del fondo con el contraste de los grises
    _, umbralBasico = cv2.threshold(imagen, valorUmbral, 255, cv2.THRESH_BINARY)

    #algoritmo para calcular el umbral ideal segun el algoritmo de otsu
    umbralCalculado, umbralOtsu = cv2.threshold(imagen, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    print(f"El umbral óptimo calculado por Otsu es: {umbralCalculado}")

    #THRESH_BINARY hacer que el fondo sea negro y el objeto blanco (por los contrastes)
    #THRESH_OTSU aplica un algoritmo estadistico descrito por gonzalez y woods

    #muestra de resultados (para esto la libreria de matplot)
    #biblioteca de nombres de las imagenes
    titulos = ['Imagen Original',
               f'Umbral Básica (T={valorUmbral})',
               f'Umbral de Otsu (T={umbralCalculado})']
    imagenes = [imagen, umbralBasico, umbralOtsu]

    plt.figure(figsize=(15, 5))#lienzo de matplot
    for i in range(3):#para cada una de las imagenes con modificaciones en su escala de grises
        plt.subplot(1, 3, i+1)#dividir en 1 fila y 3 columnas
        plt.imshow(imagenes[i], cmap='gray')#forzar a que las imagenes se pinten en escala de grises
        plt.title(titulos[i])#titulos de las imagenes
        plt.axis('off') #ocultar los ejes del lienzo para ver mejor las imagenes

    plt.tight_layout()#acomodar automaticamente
    plt.show()#mostrar

#por fin ejecutar
if __name__ == "__main__":
    segmentarImagen(r'/content/h1.png')
