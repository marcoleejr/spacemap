# SpaceMap

**English:** [README.md](README.md)

SpaceMap es un inspector de uso de disco para macOS: rápido y local. Analiza una carpeta (tu carpeta personal por defecto) y la convierte en un treemap interactivo, para que veas dónde vive el espacio, inspecciones cualquier elemento en contexto y lo muevas a la papelera — siempre con confirmación, la app nunca borra nada para siempre.


## Funciones

- Treemap anidado interactivo: modos **Tamaño**, **Archivos** y **Antigüedad**
- Interruptores de archivos ocultos y tamaño aparente, profundidad ajustable (1–8)
- Navegación por ruta, control total por teclado, filtro por nombre
- Inspector de selección con porcentaje, conteos, antigüedad y tipo
- **Vale la pena revisar**: primero lo regenerable (compilaciones, cachés, espacios de agente, repositorios grandes), luego lo viejo
- Panel de disco con libre/usado/total del volumen analizado
- Mostrar en Finder y Mover a la papelera (confirmado)
- Análisis incrementales y cancelables que nunca siguen symlinks ni cruzan volúmenes
- Mover a la Papelera actualiza el mapa en el acto: resta el tamaño hasta la raíz, sin volver a escanear
- Actualización en vivo con FSEvents: solo se releen las carpetas que cambiaron (en Finder o en otra app)
- Abre al instante con el mapa anterior (caché en disco) y se pone al día con el historial de FSEvents
- Liviana: árbol compacto (~50 bytes por entrada, nombres internados) y sin trabajo ni redibujos mientras nada cambia
- Funciona con resultados parciales sin Acceso Total al Disco
- Localizado en 6 idiomas (inglés, español, portugués, francés, alemán, japonés) — usa el idioma del sistema, con modo claro y oscuro

## Requisitos

- macOS 14+
- Toolchain de Swift 6 (solo para compilar desde fuente)

## Compilar

```sh
scripts/build-app.sh   # produce build/SpaceMap.app
open build/SpaceMap.app
```

El bundle incluye el catálogo `Localizable` compilado (la toolchain de Swift lo
genera desde `Sources/SpaceMap/Resources/Localizable.xcstrings`, sin Xcode) y
un ícono generado por `scripts/make-icon.sh` desde `scripts/icon.swift`.

## Pruebas

```sh
swift test        # 32 casos XCTest: clasificador, squarify, escáner, catálogo, deltas, FSEvents, caché
swift run -c release spacemap-bench ~   # rendimiento del motor en ~
```

## Privacidad

SpaceMap no hace red. Todo el análisis es local. Sin Acceso Total al Disco,
las carpetas protegidas por TCC (`~/Library/Mail`, `~/Library/Messages`,
`~/Library/Safari`, `~/Library/Photos`, `~/Library/Calendars`, fototecas) se
omiten por ruta — la app nunca dispara cascadas de avisos de privacidad — y el
banner ofrece el atajo para activarlo.

### Firma y Acceso Total al Disco

macOS recuerda el Acceso Total al Disco por firma de código. Una firma ad-hoc
cambia en cada compilación, así que macOS olvidaría el permiso tras cada
rebuild. Por eso `scripts/build-app.sh` firma con la primera identidad
`Apple Development` del llavero (se puede fijar con `SPACEMAP_SIGN_IDENTITY`) y
solo usa ad-hoc, con advertencia, si no hay ninguna. SpaceMap detecta el acceso
abriendo de verdad un elemento protegido (`TCC.db`, `~/Library/Safari`, …) y
lo vuelve a comprobar cada vez que la app pasa al frente, así que el banner
desaparece sin reiniciar después de dar el permiso en Ajustes del Sistema.

## Atajos

| Tecla | Acción |
|---|---|
| `space` | marcar para revisar |
| `enter` | abrir (acercar carpeta / mostrar archivo) |
| `⌫` | subir una carpeta |
| `c` | revisar marcados |
| `hjkl` / flechas | mover selección |
| `/` | filtrar por nombre |
| `[` `]` | profundidad |
| `t` | alternar Tamaño / Archivos / Antigüedad |
| `0` | volver a la raíz |
| `r` | reanalizar |
| `?` | todos los atajos |

## Estructura

- `Sources/SpaceMap` — app SwiftUI (vistas, tema, acceso a localizaciones)
- `Sources/SpaceMap/Resources/Localizable.xcstrings` — fuente de traducciones
- `Sources/SpaceMapCore` — motor de análisis, clasificador, layout, formato
- `Sources/SpaceMapBench` — sonda CLI de rendimiento `spacemap-bench`
- `Tests/SpaceMapCoreTests` — batería de pruebas (incluye cobertura del catálogo)
- `scripts/` — `build-app.sh`, `make-icon.sh`, `icon.swift`, `strings.py`
- `docs/screens/` — capturas reales de un análisis de ~

## Licencia

MIT — ver [LICENSE](LICENSE).
