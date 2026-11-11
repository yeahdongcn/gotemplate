///|
/// A Helm-style manifest template, to show the pieces working together.
const MANIFEST : String =
  #|{{- define "labels" -}}
  #|{{- range $k, $v := . }}
  #|    {{ $k }}: {{ $v | printf "%q" }}
  #|{{- end }}
  #|{{- end -}}
  #|apiVersion: apps/v1
  #|kind: Deployment
  #|metadata:
  #|  name: {{ .name }}
  #|  labels:
  #|    {{- template "labels" .labels }}
  #|spec:
  #|  replicas: {{ or .replicas 1 }}
  #|  template:
  #|    spec:
  #|      containers:
  #|      {{- range .containers }}
  #|        - name: {{ .name }}
  #|          image: {{ printf "%s:%s" .image (or .tag "latest") }}
  #|          {{- with .ports }}
  #|          ports:
  #|          {{- range . }}
  #|            - containerPort: {{ . }}
  #|          {{- end }}
  #|          {{- end }}
  #|          {{- if gt (len .env) 0 }}
  #|          env:
  #|          {{- range $name, $value := .env }}
  #|            - name: {{ $name }}
  #|              value: {{ $value | printf "%q" }}
  #|          {{- end }}
  #|          {{- end }}
  #|      {{- end }}
  #|

///|
const VALUES : String =
  #|{
  #|  "name": "inference",
  #|  "replicas": 2,
  #|  "labels": {"app": "inference", "tier": "gpu"},
  #|  "containers": [
  #|    {"name": "server", "image": "example/server", "tag": "v0.3",
  #|     "ports": [8000, 9090], "env": {"MODEL": "qwen", "LOG_LEVEL": "info"}},
  #|    {"name": "sidecar", "image": "example/metrics", "env": {}}
  #|  ]
  #|}

///|
fn main {
  let values = @json.parse(VALUES, preserve_number_repr=true) catch {
    err => {
      println("bad values: \{err}")
      return
    }
  }
  let out = @lib.render(MANIFEST, @lib.Value::from_json(values)) catch {
    err => {
      println(err)
      return
    }
  }
  println(out)
}
