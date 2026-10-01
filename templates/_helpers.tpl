{{/*
Fails the render if networking.type isn't one of the gateway implementations this chart actually
has templates for. Extend $supported (and add the matching networking.<type> values block +
template conditionals, e.g. templates/ingress.yaml) when a new type is implemented - do not just
add it to values.yaml alone.
*/}}
{{- define "k8s-cloud.validateNetworkingType" -}}
{{- $supported := list "ingress" "nodeport" "route" -}}
{{- if not (has .Values.networking.type $supported) -}}
{{- fail (printf "networking.type %q is not supported - must be one of: %s" .Values.networking.type (join ", " $supported)) -}}
{{- end -}}
{{- end -}}

{{/*
Base URL of the Portal as reached from a browser or from Keycloak's own redirect/issuer URLs.

- networking.type=ingress/route: the single Ingress (or OpenShift Route) gateway
  (.Values.gateway.protocol/host/port).
- networking.type=nodeport: plain HTTP straight to the Portal's own NodePort - there is no shared
  gateway host/port pair in this mode (see templates/highlightportal-service.yaml), so
  gateway.protocol/port are ignored and gateway.host is reused only as the reachable node
  hostname/IP.
*/}}
{{- define "k8s-cloud.gatewayBaseURL" -}}
{{- if eq .Values.networking.type "nodeport" -}}
{{- printf "http://%s:%v" .Values.gateway.host .Values.networking.nodeport.portalPort -}}
{{- else -}}
{{- $protocol := .Values.gateway.protocol -}}
{{- $host := .Values.gateway.host -}}
{{- $port := .Values.gateway.port -}}
{{- if and $port (not (or (and (eq $protocol "http") (eq ($port | toString) "80")) (and (eq $protocol "https") (eq ($port | toString) "443")))) -}}
{{- printf "%s://%s:%v" $protocol $host $port -}}
{{- else -}}
{{- printf "%s://%s" $protocol $host -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Base URL of Keycloak as reached from a browser (login redirects) and from the Portal pod itself
(admin API calls, health checks) - i.e. everything but Keycloak's own internal SPI callbacks, which
stay on the in-cluster Service DNS name (see KC_SPI_EVENTS_LISTENER_HL_EVENT_WEBHOOK_URL in templates/keycloak-configmap.yaml).

- networking.type=ingress: same gateway host/port as the Portal, routed to Keycloak under /auth by
  the shared Ingress (see templates/ingress.yaml) - identical to k8s-cloud.gatewayBaseURL.
- networking.type=nodeport: Keycloak has its own NodePort, separate from the Portal's (see
  templates/keycloak-service.yaml), so this is a different host:port than the Portal's base URL.
*/}}
{{- define "k8s-cloud.keycloakBaseURL" -}}
{{- if eq .Values.networking.type "nodeport" -}}
{{- printf "http://%s:%v" .Values.gateway.host .Values.networking.nodeport.keycloakPort -}}
{{- else -}}
{{- include "k8s-cloud.gatewayBaseURL" . -}}
{{- end -}}
{{- end -}}

{{/*
True (non-empty) when containers must comply with the "restricted" Pod Security Standard - either
explicitly (RestrictedSecurityMode) or because OpenShift's restricted-v2 SCC enforces it anyway.
*/}}
{{- define "k8s-cloud.restricted" -}}
{{- if or .Values.openshift.enabled .Values.RestrictedSecurityMode }}true{{ end -}}
{{- end -}}

{{/*
Pod-level securityContext.

- openshift.enabled: compatible with OpenShift's default restricted-v2 SCC - no fixed UID/GID/
  fsGroup at all (restricted-v2 rejects any outside the namespace's assigned range; OpenShift picks
  a random UID from it, runs the container with supplemental group 0, and chowns volumes to the
  namespace's fsGroup itself), only the fields the "restricted" Pod Security Standard requires.
- RestrictedSecurityMode (plain Kubernetes): the same restricted fields, plus the component's own
  non-zero fsGroup (nothing assigns one for us here), only re-chowning volumes whose root doesn't
  already match it.
- otherwise: just the optional non-zero fsGroup passed in (see HighlightPortal/Keycloak.fsGroup in
  values.yaml), or nothing.

Usage: include "k8s-cloud.podSecurityContext" (dict "root" $ "fsGroup" .Values.X.fsGroup)
*/}}
{{- define "k8s-cloud.podSecurityContext" -}}
{{- if include "k8s-cloud.restricted" .root }}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  {{- if and .fsGroup (not .root.Values.openshift.enabled) }}
  fsGroup: {{ .fsGroup }}
  fsGroupChangePolicy: OnRootMismatch
  {{- end }}
{{- else if .fsGroup }}
securityContext:
  fsGroup: {{ .fsGroup }}
{{- end }}
{{- end -}}

{{/*
Container-level securityContext required by restricted-v2 / the "restricted" Pod Security Standard.
Emitted only in restricted mode (openshift.enabled or RestrictedSecurityMode), so default plain
Kubernetes deployments are left unchanged.

- RestrictedSecurityMode additionally makes the root filesystem read-only - every path the app
  writes to is then a PVC or an emptyDir (see "k8s-cloud.restricted" uses in the workload templates).
- runAsUser/runAsGroup (optional) pin the image's non-root UID/GID on plain Kubernetes, since
  runAsNonRoot can only verify a numeric image USER (and the postgres image starts as root). Never
  set on OpenShift, where the SCC assigns the UID.

Usage: include "k8s-cloud.containerSecurityContext" (dict "root" $ "runAsUser" .Values.X.runAsUser)
*/}}
{{- define "k8s-cloud.containerSecurityContext" -}}
{{- if include "k8s-cloud.restricted" .root }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  {{- if .root.Values.RestrictedSecurityMode }}
  readOnlyRootFilesystem: true
  {{- end }}
  {{- if and .runAsUser (not .root.Values.openshift.enabled) }}
  runAsUser: {{ .runAsUser }}
  runAsGroup: {{ .runAsGroup | default .runAsUser }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
spec.tls block shared by both OpenShift Routes (templates/routes.yaml). Edge termination at the
router. With networking.route.tls.certificate/key left empty, the router's default certificate
(wildcard *.apps.<cluster-domain>) is served - only valid if gateway.host is under that domain.
*/}}
{{- define "k8s-cloud.routeTLS" -}}
{{- if .Values.networking.route.tls.enabled }}
tls:
  termination: edge
  insecureEdgeTerminationPolicy: Redirect
  {{- with .Values.networking.route.tls.certificate }}
  certificate: {{ . | quote }}
  {{- end }}
  {{- with .Values.networking.route.tls.key }}
  key: {{ . | quote }}
  {{- end }}
  {{- with .Values.networking.route.tls.caCertificate }}
  caCertificate: {{ . | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Name of the Kubernetes Secret holding every password, client secret, API key and license key:
.Values.existingSecret when set (externally managed - e.g. synced by External Secrets Operator,
a CSI secret store or Sealed Secrets), otherwise the one this chart renders from the values files
(templates/highlight-secret.yaml). See existingSecret in values.yaml for the keys it must contain.
*/}}
{{- define "k8s-cloud.secretName" -}}
{{- .Values.existingSecret | default "highlight-pwd-sec" -}}
{{- end -}}

{{/*
One container env entry read from a key of the "k8s-cloud.secretName" Secret. optional=true lets an
existingSecret omit the key (the variable is then left unset) - only used for values that can
legitimately be absent (SMTP passwords, unused license keys).

Usage: include "k8s-cloud.secretEnv" (dict "root" $ "name" "ENV_VAR" "key" "secret-key" "optional" true)
*/}}
{{- define "k8s-cloud.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "k8s-cloud.secretName" .root }}
      key: {{ .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end -}}
