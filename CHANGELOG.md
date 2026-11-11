# Ferry — historial de versiones

Versión actual: ver el archivo `VERSION`. Para publicar una nueva, cambia `VERSION`
y ejecuta `./make-dmg.sh`.

## 1.4.1 — 2026-11-11 · Seguridad
- **El enlace `ferry://bring` ya no actúa sin preguntar.** Valida la ruta (debe ser una carpeta existente y escribible; se rechazan `~/Library`, carpetas del sistema y carpetas ocultas), muestra siempre una confirmación con la ruta completa y solo **copia**: nunca mueve los originales cuando la orden viene de un enlace. Un enlace de una web ya no puede mandar tus archivos a donde quiera. La Acción rápida «Traer de Ferry» sigue funcionando y ahora pasa por esa confirmación.
- El historial de «Cortados» se valida antes de borrar o mover algo: un `estado.json` alterado ya no puede hacer que Ferry toque archivos fuera de su carpeta.
- Al pegar con ⌘V, Ferry solo restaura tu portapapeles si no copiaste nada mientras tanto, marca lo que escribe como temporal y no respalda contenido oculto (por ejemplo, contraseñas de un gestor).
- Las carpetas de Ferry y su estado se crean solo para tu usuario (permisos 0700 y 0600), y los temporales viejos se limpian también al abrir.

## 1.4.0 — 2026-11-10
- **Ventana de Ajustes** (menú → Ajustes…, ⌘,): cambiar el atajo de pegado, el tiempo de auto-ocultado (5 s a nunca), dónde aparece la estantería y la sensibilidad del «sacudir».
- **Inglés además de español**: la app sigue el idioma del sistema.

## 1.3.0 — 2026-11-10
- **Convertir imágenes al soltar** (opción del menú «Preguntar al soltar imágenes», apagada por defecto): al soltar una imagen en otra app, Ferry pregunta si entregarla Original, en JPG, en PNG o reducida (JPG, 1600 px). Se pregunta una vez por arrastre y se aplica a todas las imágenes.

## 1.2.1 — 2026-11-10
- Icono propio de la app (barco negro sobre baldosa blanca) en el Finder, el Dock y el DMG.

## 1.2.0 — 2026-11-10
- **Traer de Ferry**: Acción rápida del Finder (clic derecho → Acciones rápidas) que trae la estantería a esa carpeta. Se instala desde el menú de Ferry.
- Esquema `ferry://bring?path=…` para automatizaciones.

## 1.1.0 — 2026-11-10
- Atajo global **⌃⌥⌘V**: pega la estantería en la carpeta del Finder o en la app activa.
- **Cortes recientes**: "Devolver al origen" por archivo (Ferry guarda los cortados 7 días).
- **Selección múltiple** y arrastre en grupo (clic para seleccionar, "Seleccionar todo").
- La estantería **se recuerda al cerrar la app** (opción en el menú).
- El arrastre ahora entrega siempre una copia y Ferry corta el original (así se puede devolver).

## 1.0.1 — 2026-11-10
- Primera versión numerada. Estantería temporal para mover archivos entre ventanas y Spaces.
- Cortar (por defecto) o copiar al soltar; conserva el nombre original.
- Se recoge sola a los 10 s si está vacía; abrir al iniciar sesión.
- Ventana "Acerca de Ferry".

© 2026 ChocolitosSoft. Todos los derechos reservados.
