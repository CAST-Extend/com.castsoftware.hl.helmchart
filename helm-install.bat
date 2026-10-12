helm upgrade --install highlight --namespace highlight --create-namespace --set version=6.0.2 -f values.yaml -f values-secret.yaml .
