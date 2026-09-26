#!/usr/bin/env python3
"""SpaceMap localization toolchain (no Xcode required).

Single source of truth: STRINGS below.
  python3 scripts/strings.py generate   -> writes Sources/SpaceMap/Resources/Localizable.xcstrings
  python3 scripts/strings.py compile <xcstrings> <ResourcesDir>
                                        -> writes <ResourcesDir>/<lang>.lproj/Localizable.strings
                                           and Localizable.stringsdict for plural keys.

The .app bundle embeds the compiled .lproj directories so Foundation
localization (NSLocalizedString + String.localizedStringWithFormat, resolved
through Bundle.module) works in builds made by plain `swift build`.
"""
import json
import plistlib
import sys
from pathlib import Path

LOCALES = ["en", "es", "pt", "fr", "de", "ja"]

# Each entry: key -> {"comment": ..., "en": ..., "es": ..., ...}
# Plural entries use {"one": {...}, "other": {...}} per locale instead of a
# plain string (ja only needs "other").
STRINGS = {
    "nav.home": {"comment": "Breadcrumb link back to the scan root home",
        "en": "home", "es": "inicio", "pt": "início", "fr": "accueil", "de": "Home", "ja": "ホーム"},
    "nav.scan_home": {"comment": "Menu item: scan the home folder",
        "en": "Scan Home", "es": "Analizar inicio", "pt": "Verificar Início", "fr": "Analyser l’accueil", "de": "Home scannen", "ja": "ホームをスキャン"},
    "nav.choose_folder": {"comment": "Menu item: pick another folder",
        "en": "Choose Folder…", "es": "Elegir carpeta…", "pt": "Escolher pasta…", "fr": "Choisir un dossier…", "de": "Ordner wählen…", "ja": "フォルダを選択…"},
    "panel.choose_title": {"comment": "Open panel title",
        "en": "Choose a folder to scan", "es": "Elige una carpeta para analizar", "pt": "Escolha uma pasta para verificar", "fr": "Choisissez un dossier à analyser", "de": "Zu scannenden Ordner wählen", "ja": "スキャンするフォルダを選択"},
    "panel.choose_message": {"comment": "Open panel message",
        "en": "SpaceMap will map this folder and items on the same volume.",
        "es": "SpaceMap mapeará esta carpeta y los elementos del mismo volumen.",
        "pt": "O SpaceMap mapeará esta pasta e os itens no mesmo volume.",
        "fr": "SpaceMap va cartographier ce dossier et les éléments du même volume.",
        "de": "SpaceMap kartiert diesen Ordner und die Inhalte desselben Volumes.",
        "ja": "SpaceMapはこのフォルダと同じボリューム内の項目をマップします。"},
    "filter.placeholder": {"comment": "Filter text field placeholder",
        "en": "Filter by name", "es": "Filtrar por nombre", "pt": "Filtrar por nome", "fr": "Filtrer par nom", "de": "Nach Namen filtern", "ja": "名前で絞り込む"},
    "mode.size": {"comment": "Treemap mode",
        "en": "Size", "es": "Tamaño", "pt": "Tamanho", "fr": "Taille", "de": "Größe", "ja": "サイズ"},
    "mode.files": {"comment": "Treemap mode",
        "en": "Files", "es": "Archivos", "pt": "Arquivos", "fr": "Fichiers", "de": "Dateien", "ja": "ファイル"},
    "mode.age": {"comment": "Treemap mode",
        "en": "Age", "es": "Antigüedad", "pt": "Idade", "fr": "Âge", "de": "Alter", "ja": "更新"},
    "toggle.hidden": {"comment": "Show hidden files toggle",
        "en": "Hidden files", "es": "Archivos ocultos", "pt": "Arquivos ocultos", "fr": "Fichiers cachés", "de": "Versteckte Dateien", "ja": "隠しファイル"},
    "toggle.apparent": {"comment": "Apparent size toggle",
        "en": "Apparent size", "es": "Tamaño aparente", "pt": "Tamanho aparente", "fr": "Taille apparente", "de": "Tatsächliche Größe", "ja": "見かけのサイズ"},
    "depth.label": {"comment": "Depth stepper label, %d is the depth",
        "en": "Depth %d", "es": "Profundidad %d", "pt": "Profundidade %d", "fr": "Profondeur %d", "de": "Tiefe %d", "ja": "深さ %d"},
    "summary.scanning": {"comment": "Prefix for partial totals while scanning",
        "en": "Scanning", "es": "Analizando", "pt": "Verificando", "fr": "Analyse", "de": "Scannen", "ja": "スキャン中"},
    "summary.empty": {"comment": "Shown before the first scan",
        "en": "No scan yet", "es": "Aún sin análisis", "pt": "Nenhuma verificação", "fr": "Pas encore d’analyse", "de": "Noch kein Scan", "ja": "未スキャン"},
    "file_count": {"comment": "Pluralized file count",
        "en": {"one": "%lld file", "other": "%lld files"},
        "es": {"one": "%lld archivo", "other": "%lld archivos"},
        "pt": {"one": "%lld arquivo", "other": "%lld arquivos"},
        "fr": {"one": "%lld fichier", "other": "%lld fichiers"},
        "de": {"one": "%lld Datei", "other": "%lld Dateien"},
        "ja": {"other": "%lldファイル"}},
    "dir_count": {"comment": "Pluralized directory count",
        "en": {"one": "%lld dir", "other": "%lld dirs"},
        "es": {"one": "%lld carpeta", "other": "%lld carpetas"},
        "pt": {"one": "%lld pasta", "other": "%lld pastas"},
        "fr": {"one": "%lld dossier", "other": "%lld dossiers"},
        "de": {"one": "%lld Ordner", "other": "%lld Ordner"},
        "ja": {"other": "%lldフォルダ"}},
    "files_compact_one": {"comment": "Singular compact file count, %@ is like 1",
        "en": "%@ file", "es": "%@ archivo", "pt": "%@ arquivo", "fr": "%@ fichier", "de": "%@ Datei", "ja": "%@ファイル"},
    "files_compact_other": {"comment": "Plural compact file count, %@ is like 4.4M",
        "en": "%@ files", "es": "%@ archivos", "pt": "%@ arquivos", "fr": "%@ fichiers", "de": "%@ Dateien", "ja": "%@ファイル"},
    "dirs_compact_one": {"comment": "Singular compact directory count",
        "en": "%@ dir", "es": "%@ carpeta", "pt": "%@ pasta", "fr": "%@ dossier", "de": "%@ Ordner", "ja": "%@フォルダ"},
    "dirs_compact_other": {"comment": "Plural compact directory count, %@ is like 808.7k",
        "en": "%@ dirs", "es": "%@ carpetas", "pt": "%@ pastas", "fr": "%@ dossiers", "de": "%@ Ordner", "ja": "%@フォルダ"},
    "status.scanning": {"comment": "Footer while scanning: count, seconds, current folder",
        "en": "scanning %@ entries · %@ s · %@", "es": "analizando %@ entradas · %@ s · %@", "pt": "verificando %@ entradas · %@ s · %@", "fr": "analyse de %@ entrées · %@ s · %@", "de": "scanne %@ Einträge · %@ s · %@", "ja": "%@エントリをスキャン中 · %@秒 · %@"},
    "status.done": {"comment": "Footer after a scan: count, seconds",
        "en": "scan %@ entries · %@ s", "es": "análisis de %@ entradas · %@ s", "pt": "verificação de %@ entradas · %@ s", "fr": "analyse de %@ entrées · %@ s", "de": "%@ Einträge · %@ s", "ja": "%@エントリ · %@秒"},
    "status.starting": {"comment": "Footer current-path placeholder",
        "en": "starting", "es": "iniciando", "pt": "iniciando", "fr": "démarrage", "de": "Start", "ja": "開始中"},
    "fda.message": {"comment": "Full Disk Access banner",
        "en": "Some protected folders are hidden. SpaceMap can still map everything it can read.",
        "es": "Algunas carpetas protegidas están ocultas. SpaceMap puede mapear todo lo que puede leer.",
        "pt": "Algumas pastas protegidas estão ocultas. O SpaceMap ainda mapeia tudo o que pode ler.",
        "fr": "Certains dossiers protégés sont masqués. SpaceMap cartographie tout ce qu’il peut lire.",
        "de": "Einige geschützte Ordner sind ausgeblendet. SpaceMap kartiert trotzdem alles Lesbare.",
        "ja": "保護されたフォルダは非表示です。SpaceMapは読み取り可能な範囲をマップします。"},
    "fda.action": {"comment": "FDA banner button",
        "en": "Enable Full Disk Access…", "es": "Activar acceso total al disco…", "pt": "Ativar acesso total ao disco…", "fr": "Activer l’accès complet au disque…", "de": "Vollzugriff aktivieren…", "ja": "フルディスクアクセスを有効化…"},
    "rail.views": {"comment": "Sidebar group",
        "en": "Views", "es": "Vistas", "pt": "Visualizações", "fr": "Vues", "de": "Ansichten", "ja": "表示"},
    "rail.display": {"comment": "Sidebar group",
        "en": "Display", "es": "Pantalla", "pt": "Exibição", "fr": "Affichage", "de": "Anzeige", "ja": "表示設定"},
    "rail.legend": {"comment": "Sidebar group",
        "en": "Legend", "es": "Leyenda", "pt": "Legenda", "fr": "Légende", "de": "Legende", "ja": "凡例"},
    "section.selection": {"comment": "Inspector section heading",
        "en": "Selection", "es": "Selección", "pt": "Seleção", "fr": "Sélection", "de": "Auswahl", "ja": "選択"},
    "section.worth": {"comment": "Inspector section heading",
        "en": "Worth a look", "es": "Vale la pena revisar", "pt": "Vale a pena ver", "fr": "À examiner", "de": "Lohnt sich", "ja": "要チェック"},
    "section.disk": {"comment": "Inspector section heading",
        "en": "Disk", "es": "Disco", "pt": "Disco", "fr": "Disque", "de": "Volume", "ja": "ディスク"},
    "sel.of_scan": {"comment": "Share-of-scan label",
        "en": "of scan", "es": "del análisis", "pt": "da verificação", "fr": "de l’analyse", "de": "vom Scan", "ja": "スキャン比"},
    "sel.files": {"comment": "File count label",
        "en": "files", "es": "archivos", "pt": "arquivos", "fr": "fichiers", "de": "Dateien", "ja": "ファイル"},
    "sel.last_write": {"comment": "Last modification label",
        "en": "Last write", "es": "Última escritura", "pt": "Última escrita", "fr": "Dernière écriture", "de": "Letzte Änderung", "ja": "最終更新"},
    "sel.kind": {"comment": "Category label",
        "en": "Kind", "es": "Tipo", "pt": "Tipo", "fr": "Type", "de": "Art", "ja": "種類"},
    "sel.empty": {"comment": "Empty selection hint",
        "en": "Select a tile to inspect it.", "es": "Selecciona un bloque para inspeccionarlo.", "pt": "Selecione um bloco para inspecioná-lo.", "fr": "Sélectionnez une tuile pour l’inspecter.", "de": "Wähle eine Kachel zur Inspektion.", "ja": "タイルを選択して詳細を表示。"},
    "action.reveal": {"comment": "Reveal in Finder button",
        "en": "Reveal", "es": "Mostrar", "pt": "Revelar", "fr": "Révéler", "de": "Zeigen", "ja": "表示"},
    "action.trash": {"comment": "Move to Trash button",
        "en": "Move to Trash", "es": "Mover a la papelera", "pt": "Mover para a Lixeira", "fr": "Mettre à la corbeille", "de": "In den Papierkorb", "ja": "ゴミ箱に入れる"},
    "trash.title": {"comment": "Trash confirmation title",
        "en": "Move to Trash?", "es": "¿Mover a la papelera?", "pt": "Mover para a Lixeira?", "fr": "Mettre à la corbeille ?", "de": "In den Papierkorb bewegen?", "ja": "ゴミ箱に入れますか?"},
    "trash.cancel": {"comment": "Cancel button",
        "en": "Cancel", "es": "Cancelar", "pt": "Cancelar", "fr": "Annuler", "de": "Abbrechen", "ja": "キャンセル"},
    "trash.note": {"comment": "Trash confirmation note, %@ is the size",
        "en": "%@ · this item will be moved to Trash, not permanently deleted.",
        "es": "%@ · este elemento se moverá a la papelera, no se eliminará para siempre.",
        "pt": "%@ · este item será movido para a Lixeira, não excluído permanentemente.",
        "fr": "%@ · cet élément ira à la corbeille, sans suppression définitive.",
        "de": "%@ · dieses Element wird in den Papierkorb bewegt, nicht endgültig gelöscht.",
        "ja": "%@ · この項目はゴミ箱に移動され、完全に削除されません。"},
    "error.trash_failed": {"comment": "Trash failure, %@ is the system error",
        "en": "Could not move item to Trash: %@", "es": "No se pudo mover a la papelera: %@", "pt": "Não foi possível mover para a Lixeira: %@", "fr": "Mise à la corbeille impossible : %@", "de": "Konnte nicht in den Papierkorb bewegt werden: %@", "ja": "ゴミ箱に移動できませんでした: %@"},
    "worth.finding": {"comment": "Worth-a-look loading state",
        "en": "Finding cleanup candidates…", "es": "Buscando candidatos…", "pt": "Buscando candidatos…", "fr": "Recherche de candidats…", "de": "Suche nach Kandidaten…", "ja": "候補を検索中…"},
    "worth.empty": {"comment": "Worth-a-look empty state",
        "en": "No large cleanup candidates found.", "es": "No se encontraron candidatos grandes.", "pt": "Nenhum candidato grande encontrado.", "fr": "Aucun candidat notable.", "de": "Keine großen Kandidaten gefunden.", "ja": "大きな候補はありません。"},
    "worth.build_output": {"comment": "Candidate subtitle",
        "en": "build output · safe to review", "es": "compilación · seguro para revisar", "pt": "build · seguro para revisar", "fr": "produit de build · à vérifier", "de": "Build-Artefakt · bitte prüfen", "ja": "ビルド成果物 · 要確認"},
    "worth.cache": {"comment": "Candidate subtitle",
        "en": "regenerable cache", "es": "caché regenerable", "pt": "cache regenerável", "fr": "cache régénérable", "de": "neu erstellbarer Cache", "ja": "再生成可能なキャッシュ"},
    "worth.agent": {"comment": "Candidate subtitle",
        "en": "agent workspace", "es": "espacio de agente", "pt": "espaço de agente", "fr": "espace d’agent", "de": "Agent-Arbeitsbereich", "ja": "エージェント作業領域"},
    "worth.repo": {"comment": "Candidate subtitle",
        "en": "large repository", "es": "repositorio grande", "pt": "repositório grande", "fr": "grand dépôt", "de": "großes Repository", "ja": "大きなリポジトリ"},
    "worth.old_media": {"comment": "Candidate subtitle",
        "en": "old media", "es": "contenido antiguo", "pt": "mídia antiga", "fr": "ancien média", "de": "alte Medien", "ja": "古いメディア"},
    "worth.old_other": {"comment": "Candidate subtitle, %@ is a relative age",
        "en": "old · last write %@", "es": "antiguo · última escritura %@", "pt": "antigo · última escrita %@", "fr": "ancien · dernière écriture %@", "de": "alt · letzte Änderung %@", "ja": "古い · 最終更新 %@"},
    "disk.free": {"comment": "Free space, %@ is the amount",
        "en": "%@ free", "es": "%@ libres", "pt": "%@ livres", "fr": "%@ libres", "de": "%@ frei", "ja": "空き %@"},
    "disk.used": {"comment": "Used space",
        "en": "%@ used", "es": "%@ usados", "pt": "%@ usados", "fr": "%@ utilisés", "de": "%@ belegt", "ja": "使用量 %@"},
    "disk.total": {"comment": "Total capacity",
        "en": "%@ total", "es": "%@ en total", "pt": "%@ no total", "fr": "%@ au total", "de": "%@ gesamt", "ja": "合計 %@"},
    "key.mark": {"comment": "Shortcut action names",
        "en": "mark", "es": "marcar", "pt": "marcar", "fr": "marquer", "de": "markieren", "ja": "マーク"},
    "key.open": {"comment": "Shortcut action names",
        "en": "open", "es": "abrir", "pt": "abrir", "fr": "ouvrir", "de": "öffnen", "ja": "開く"},
    "key.up": {"comment": "Shortcut action names",
        "en": "up", "es": "subir", "pt": "subir", "fr": "monter", "de": "hoch", "ja": "上へ"},
    "key.review": {"comment": "Shortcut action names",
        "en": "review", "es": "revisar", "pt": "revisar", "fr": "vérifier", "de": "prüfen", "ja": "確認"},
    "key.move": {"comment": "Shortcut action names",
        "en": "move", "es": "mover", "pt": "mover", "fr": "déplacer", "de": "bewegen", "ja": "移動"},
    "key.filter": {"comment": "Shortcut action names",
        "en": "filter", "es": "filtrar", "pt": "filtrar", "fr": "filtrer", "de": "filtern", "ja": "絞り込み"},
    "key.depth": {"comment": "Shortcut action names",
        "en": "depth", "es": "profundidad", "pt": "profundidade", "fr": "profondeur", "de": "Tiefe", "ja": "深さ"},
    "key.mode": {"comment": "Shortcut action names",
        "en": "mode", "es": "modo", "pt": "modo", "fr": "mode", "de": "Modus", "ja": "モード"},
    "key.reset": {"comment": "Shortcut action names",
        "en": "reset", "es": "restablecer", "pt": "redefinir", "fr": "réinitialiser", "de": "zurücksetzen", "ja": "リセット"},
    "key.rescan": {"comment": "Shortcut action names",
        "en": "rescan", "es": "reanalizar", "pt": "verificar de novo", "fr": "réanalyser", "de": "erneut scannen", "ja": "再スキャン"},
    "keys.all": {"comment": "Footer link",
        "en": "all keys", "es": "todas las teclas", "pt": "todas as teclas", "fr": "toutes les touches", "de": "alle Tasten", "ja": "全てのキー"},
    "keys.help_tip": {"comment": "Show shortcuts tooltip",
        "en": "Show all keyboard shortcuts", "es": "Mostrar todos los atajos de teclado", "pt": "Mostrar todos os atalhos de teclado", "fr": "Afficher tous les raccourcis clavier", "de": "Alle Tastenkürzel anzeigen", "ja": "全てのキーボードショートカットを表示"},
    "keys.cancel_scan": {"comment": "Cancel scan tooltip",
        "en": "Cancel scan", "es": "Cancelar análisis", "pt": "Cancelar verificação", "fr": "Annuler l’analyse", "de": "Scan abbrechen", "ja": "スキャンを中止"},
    "review.title": {"comment": "Review sheet title",
        "en": "Marked for review", "es": "Marcados para revisar", "pt": "Marcados para revisão", "fr": "À vérifier", "de": "Zur Prüfung vorgemerkt", "ja": "確認用にマーク"},
    "review.subtitle": {"comment": "Review sheet subtitle",
        "en": "Nothing is removed until you confirm a move to Trash.",
        "es": "Nada se elimina hasta que confirmes mover a la papelera.",
        "pt": "Nada é removido até você confirmar mover para a Lixeira.",
        "fr": "Rien n’est supprimé avant confirmation.",
        "de": "Nichts wird ohne bestätigtes Verschieben gelöscht.",
        "ja": "ゴミ箱への移動を確定するまで何も削除されません。"},
    "review.done": {"comment": "Review sheet button",
        "en": "Done", "es": "Listo", "pt": "OK", "fr": "OK", "de": "Fertig", "ja": "完了"},
    "review.empty_title": {"comment": "Review sheet empty title",
        "en": "No marked items", "es": "Sin elementos marcados", "pt": "Nenhum item marcado", "fr": "Aucun élément marqué", "de": "Keine vorgemerkten Elemente", "ja": "マークされた項目なし"},
    "review.empty_hint": {"comment": "Review sheet empty hint",
        "en": "Select an item and press Space to add it here.",
        "es": "Selecciona un elemento y pulsa Espacio para añadirlo aquí.",
        "pt": "Selecione um item e pressione Espaço para adicioná-lo aqui.",
        "fr": "Sélectionnez un élément et appuyez sur Espace pour l’ajouter ici.",
        "de": "Wähle ein Element und drücke die Leertaste, um es hierher zu holen.",
        "ja": "項目を選択してスペースキーを押すとここに追加されます。"},
    "review.trash_tip": {"comment": "Review row trash tooltip",
        "en": "Move to Trash", "es": "Mover a la papelera", "pt": "Mover para a Lixeira", "fr": "Mettre à la corbeille", "de": "In den Papierkorb", "ja": "ゴミ箱に入れる"},
    "help.title": {"comment": "Shortcuts overlay title",
        "en": "Keyboard map", "es": "Mapa de teclado", "pt": "Mapa de teclado", "fr": "Raccourcis clavier", "de": "Tastaturbelegung", "ja": "キーボードマップ"},
    "help.mark": {"comment": "Shortcut explanations",
        "en": "Mark or unmark selection", "es": "Marcar o desmarcar la selección", "pt": "Marcar ou desmarcar a seleção", "fr": "Marquer la sélection ou non", "de": "Auswahl markieren oder nicht", "ja": "選択をマーク/解除"},
    "help.open": {"comment": "Shortcut explanations",
        "en": "Zoom into a folder / reveal a file", "es": "Acercar una carpeta / mostrar un archivo", "pt": "Aproximar uma pasta / revelar um arquivo", "fr": "Explorer un dossier / révéler un fichier", "de": "Ordner öffnen / Datei zeigen", "ja": "フォルダをズーム/ファイルを表示"},
    "help.up": {"comment": "Shortcut explanations",
        "en": "Move up one folder", "es": "Subir una carpeta", "pt": "Subir uma pasta", "fr": "Remonter d’un dossier", "de": "Eine Ebene hoch", "ja": "1つ上のフォルダへ"},
    "help.review": {"comment": "Shortcut explanations",
        "en": "Review marked items", "es": "Revisar marcados", "pt": "Revisar marcados", "fr": "Vérifier les éléments marqués", "de": "Vorgemerkte prüfen", "ja": "マーク済みを確認"},
    "help.move": {"comment": "Shortcut explanations",
        "en": "Move selection among siblings", "es": "Mover la selección entre hermanos", "pt": "Mover a seleção entre irmãos", "fr": "Déplacer la sélection entre voisins", "de": "Auswahl zwischen Nachbarn bewegen", "ja": "選択を兄弟間で移動"},
    "help.filter": {"comment": "Shortcut explanations",
        "en": "Filter names", "es": "Filtrar nombres", "pt": "Filtrar nomes", "fr": "Filtrer les noms", "de": "Namen filtern", "ja": "名前で絞り込み"},
    "help.depth": {"comment": "Shortcut explanations",
        "en": "Decrease or increase depth", "es": "Reducir o aumentar la profundidad", "pt": "Diminuir ou aumentar a profundidade", "fr": "Réduire ou augmenter la profondeur", "de": "Tiefe verringern oder erhöhen", "ja": "深さを増減"},
    "help.mode": {"comment": "Shortcut explanations, three mode names",
        "en": "Cycle %@ / %@ / %@", "es": "Alternar %@ / %@ / %@", "pt": "Alternar %@ / %@ / %@", "fr": "Alterner %@ / %@ / %@", "de": "Wechseln %@ / %@ / %@", "ja": "%@/%@/%@を切り替え"},
    "help.reset": {"comment": "Shortcut explanations",
        "en": "Reset to scan root", "es": "Volver a la raíz del análisis", "pt": "Voltar à raiz da verificação", "fr": "Revenir à la racine", "de": "Zur Scan-Wurzel", "ja": "スキャン起点に戻る"},
    "help.rescan": {"comment": "Shortcut explanations",
        "en": "Rescan", "es": "Reanalizar", "pt": "Verificar de novo", "fr": "Réanalyser", "de": "Erneut scannen", "ja": "再スキャン"},
    "help.dismiss": {"comment": "Shortcut explanations",
        "en": "Show or dismiss this map", "es": "Mostrar u ocultar este mapa", "pt": "Mostrar ou ocultar este mapa", "fr": "Afficher ou masquer cette carte", "de": "Diese Übersicht zeigen oder schließen", "ja": "このマップを表示/閉じる"},
    "help.footnote": {"comment": "Shortcuts overlay footnote",
        "en": "Deleting always means Move to Trash with a confirmation. SpaceMap never permanently deletes files.",
        "es": "Eliminar siempre significa mover a la papelera con confirmación. SpaceMap nunca borra archivos para siempre.",
        "pt": "Excluir sempre significa mover para a Lixeira com confirmação. O SpaceMap nunca exclui arquivos permanentemente.",
        "fr": "Supprimer signifie toujours mettre à la corbeille avec confirmation. SpaceMap ne supprime jamais définitivement.",
        "de": "Löschen heißt immer: mit Bestätigung in den Papierkorb. SpaceMap löscht nie endgültig.",
        "ja": "削除は常に確認の上でゴミ箱への移動です。SpaceMapが完全に削除することはありません。"},
    "canvas.empty_title": {"comment": "Empty folder title",
        "en": "This folder is empty", "es": "Esta carpeta está vacía", "pt": "Esta pasta está vazia", "fr": "Ce dossier est vide", "de": "Dieser Ordner ist leer", "ja": "このフォルダは空です"},
    "canvas.empty_hint": {"comment": "Empty folder hint",
        "en": "Choose another folder to inspect its contents.", "es": "Elige otra carpeta para inspeccionar su contenido.", "pt": "Escolha outra pasta para inspecionar seu conteúdo.", "fr": "Choisissez un autre dossier pour voir son contenu.", "de": "Wähle einen anderen Ordner zur Inspektion.", "ja": "別のフォルダを選択して内容を確認。"},
    "canvas.loading_title": {"comment": "Scanning placeholder title",
        "en": "Mapping this volume…", "es": "Mapeando este volumen…", "pt": "Mapeando este volume…", "fr": "Cartographie du volume…", "de": "Volume wird kartiert…", "ja": "ボリュームをマップ中…"},
    "canvas.loading_hint": {"comment": "Scanning placeholder hint",
        "en": "The treemap will fill in as entries are discovered.", "es": "El mapa se llenará a medida que se descubran entradas.", "pt": "O mapa será preenchido conforme itens forem descobertos.", "fr": "La carte se remplira au fil de la découverte.", "de": "Die Karte füllt sich mit jedem Fund.", "ja": "見つかった項目からマップが埋まります。"},
    "canvas.accessibility": {"comment": "Treemap VoiceOver label",
        "en": "Disk usage treemap", "es": "Mapa de uso del disco", "pt": "Mapa de uso do disco", "fr": "Carte d’utilisation du disque", "de": "Treemap der Belegung", "ja": "ディスク使用量マップ"},
    "category.reclaimable": {"comment": "Category names",
        "en": "Reclaimable", "es": "Recuperable", "pt": "Recuperável", "fr": "Récupérable", "de": "Wiederherstellbar", "ja": "再利用可能"},
    "category.code": {"comment": "Category names",
        "en": "Code", "es": "Código", "pt": "Código", "fr": "Code", "de": "Code", "ja": "コード"},
    "category.agent": {"comment": "Category names",
        "en": "Agent scratch", "es": "Restos de agente", "pt": "Restos de agente", "fr": "Résidus d’agent", "de": "Agent-Reste", "ja": "エージェント残渣"},
    "category.toolchains": {"comment": "Category names",
        "en": "Toolchains", "es": "Cadenas de herramientas", "pt": "Toolchains", "fr": "Chaînes d’outils", "de": "Toolchains", "ja": "ツールチェイン"},
    "category.synced": {"comment": "Category names",
        "en": "Synced", "es": "Sincronizado", "pt": "Sincronizado", "fr": "Synchronisé", "de": "Synchronisiert", "ja": "同期済み"},
    "category.git": {"comment": "Category names",
        "en": "Git", "es": "Git", "pt": "Git", "fr": "Git", "de": "Git", "ja": "Git"},
    "category.media": {"comment": "Category names",
        "en": "Media", "es": "Multimedia", "pt": "Mídia", "fr": "Médias", "de": "Medien", "ja": "メディア"},
    "category.documents": {"comment": "Category names",
        "en": "Documents", "es": "Documentos", "pt": "Documentos", "fr": "Documents", "de": "Dokumente", "ja": "ドキュメント"},
    "category.cache": {"comment": "Category names",
        "en": "Cache", "es": "Caché", "pt": "Cache", "fr": "Cache", "de": "Cache", "ja": "キャッシュ"},
    "age.just_now": {"comment": "Relative age",
        "en": "just now", "es": "ahora mismo", "pt": "agora mesmo", "fr": "à l’instant", "de": "gerade eben", "ja": "たった今"},
    "age.unknown": {"comment": "Unknown age",
        "en": "Unknown", "es": "Desconocido", "pt": "Desconhecido", "fr": "Inconnue", "de": "Unbekannt", "ja": "不明"},
    "age.minute": {"comment": "Pluralized minutes ago",
        "en": {"one": "%lld minute ago", "other": "%lld minutes ago"},
        "es": {"one": "hace %lld minuto", "other": "hace %lld minutos"},
        "pt": {"one": "há %lld minuto", "other": "há %lld minutos"},
        "fr": {"one": "il y a %lld minute", "other": "il y a %lld minutes"},
        "de": {"one": "vor %lld Minute", "other": "vor %lld Minuten"},
        "ja": {"other": "%lld分前"}},
    "age.hour": {"comment": "Pluralized hours ago",
        "en": {"one": "%lld hour ago", "other": "%lld hours ago"},
        "es": {"one": "hace %lld hora", "other": "hace %lld horas"},
        "pt": {"one": "há %lld hora", "other": "há %lld horas"},
        "fr": {"one": "il y a %lld heure", "other": "il y a %lld heures"},
        "de": {"one": "vor %lld Stunde", "other": "vor %lld Stunden"},
        "ja": {"other": "%lld時間前"}},
    "age.day": {"comment": "Pluralized days ago",
        "en": {"one": "%lld day ago", "other": "%lld days ago"},
        "es": {"one": "hace %lld día", "other": "hace %lld días"},
        "pt": {"one": "há %lld dia", "other": "há %lld dias"},
        "fr": {"one": "il y a %lld jour", "other": "il y a %lld jours"},
        "de": {"one": "vor %lld Tag", "other": "vor %lld Tagen"},
        "ja": {"other": "%lld日前"}},
    "age.month": {"comment": "Pluralized months ago",
        "en": {"one": "%lld month ago", "other": "%lld months ago"},
        "es": {"one": "hace %lld mes", "other": "hace %lld meses"},
        "pt": {"one": "há %lld mês", "other": "há %lld meses"},
        "fr": {"one": "il y a %lld mois", "other": "il y a %lld mois"},
        "de": {"one": "vor %lld Monat", "other": "vor %lld Monaten"},
        "ja": {"other": "%lldか月前"}},
    "age.year": {"comment": "Pluralized years ago",
        "en": {"one": "%lld year ago", "other": "%lld years ago"},
        "es": {"one": "hace %lld año", "other": "hace %lld años"},
        "pt": {"one": "há %lld ano", "other": "há %lld anos"},
        "fr": {"one": "il y a %lld an", "other": "il y a %lld ans"},
        "de": {"one": "vor %lld Jahr", "other": "vor %lld Jahren"},
        "ja": {"other": "%lld年前"}},
}


def is_plural(value):
    return isinstance(value, dict)


def generate(xcstrings_path):
    strings = {}
    for key, entry in STRINGS.items():
        localizations = {}
        for locale in LOCALES:
            value = entry[locale]
            if is_plural(value):
                variations = {
                    category: {"stringUnit": {"state": "translated", "value": text}}
                    for category, text in value.items()
                }
                localizations[locale] = {"variations": {"plural": variations}}
            else:
                localizations[locale] = {"stringUnit": {"state": "translated", "value": value}}
        strings[key] = {"comment": entry.get("comment", ""), "extractionState": "manual",
                        "localizations": localizations}
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    Path(xcstrings_path).write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {xcstrings_path} ({len(strings)} keys x {len(LOCALES)} locales)")


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def compile_catalog(xcstrings_path, resources_dir):
    """Compile Localizable.xcstrings into <lang>.lproj/{Localizable.strings,Localizable.stringsdict}."""
    catalog = json.loads(Path(xcstrings_path).read_text(encoding="utf-8"))
    out = Path(resources_dir)
    for locale, lang in [("en", "en"), ("es", "es"), ("pt", "pt"), ("fr", "fr"), ("de", "de"), ("ja", "ja")]:
        lproj = out / f"{lang}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)
        strings_lines = []
        dict_entries = {}
        for key, entry in catalog["strings"].items():
            loc = entry["localizations"][locale]
            if "stringUnit" in loc:
                strings_lines.append(f'"{escape(key)}" = "{escape(loc["stringUnit"]["value"])}";')
            else:
                plural = loc["variations"]["plural"]
                var = {"NSStringFormatSpecTypeKey": "NSStringFormatValueTypeKey",
                       "NSStringFormatValueTypeKey": "lld"}
                for category, unit in plural.items():
                    var[category] = unit["stringUnit"]["value"]
                dict_entries[key] = {"NSStringLocalizedFormatKey": "%#@value@",
                                     "value": var}
        (lproj / "Localizable.strings").write_text("\n".join(strings_lines) + "\n", encoding="utf-8")
        with (lproj / "Localizable.stringsdict").open("wb") as f:
            plistlib.dump(dict_entries, f)
    print(f"compiled {len(LOCALES)} locales into {out}")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("generate", "compile"):
        sys.exit("usage: strings.py generate | compile <xcstrings> <resourcesDir>")
    if sys.argv[1] == "generate":
        repo = Path(__file__).resolve().parent.parent
        generate(repo / "Sources/SpaceMap/Resources/Localizable.xcstrings")
    else:
        compile_catalog(sys.argv[2], sys.argv[3])
