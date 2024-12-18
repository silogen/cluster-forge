Set FontSize 20
Set Height 800
Set WindowBar Colorful
Set Shell zsh
Sleep 1s
Type "vi working/grafana/PersistentVolumeClaim_grafana.yaml"
Sleep 500ms
Enter
Sleep 500ms
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[B"
Escape
Type "[BA"
Enter
Sleep 500ms
Type "  storageClassName: {{ .observed.composite.resource.spec.storageClass }}"
Sleep 2s
Escape
Type ":wq"
Enter
Sleep 1s
Type "cat "
Sleep 1s
Type "working/grafana/PersistentVolumeClaim_grafana.yaml"
Sleep 500ms
Enter
Sleep 3s