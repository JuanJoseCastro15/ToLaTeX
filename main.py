import cv2
import numpy as np
import os


# Leer la imagen, convertirla a escala de grises y suavizarla
original = cv2.imread("01_image.jpg")
imagen = original.copy()
gris = cv2.cvtColor(imagen, cv2.COLOR_BGR2GRAY)
filtroBorde = cv2.GaussianBlur(gris, (1, 1), 0)
filtroEsquina = cv2.GaussianBlur(gris, (11, 11), 0)

# Detectar bordes en la imagen usando Canny
bordes = cv2.Canny(filtroBorde, 120, 200)


# Algoritmo detector de esquinas 
espacioEsquina=  cv2.Canny(filtroEsquina, 30, 150)
espacioEsquina = np.float32(espacioEsquina)

esquina = cv2.cornerHarris(espacioEsquina, 14, 5, 0.04)

# Ampliamos el tamaño de las esquinas para que sea visible
esquina = cv2.dilate(esquina,None)

# Definimos un umbral. Si el valor en 'esquina' es mayor al 33% del valor máximo, es una esquina.
umbral = .33 * esquina.max()


# Cambiamos el color en la imagen original
original[esquina > umbral] = [0, 0, 255]  # Aqui eliges el color  (Es rojo puro)


# Visualizar resultados
cv2.imshow("Imagen original", imagen)
cv2.imshow("Imagen suavisada ", filtroBorde)
cv2.imshow("Detector de bordes", bordes)
cv2.imshow("Detector de esquinas", original)
cv2.waitKey(0)
cv2.destroyAllWindows()