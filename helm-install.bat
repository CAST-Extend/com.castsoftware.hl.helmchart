helm upgrade --install highlight --namespace highlight --create-namespace --set version=6.0.1 -f values.yaml -f values-secret.yaml .
