@echo off

set NAMESPACE=highlight

echo ============================================================
echo  WARNING: this deletes the PersistentVolumeClaims below from
echo  namespace "%NAMESPACE%": db-data-highlight, tmp-highlight, keycloak-data.
echo  They carry "helm.sh/resource-policy: keep", so "helm uninstall"
echo  leaves them alone - this script bypasses that on purpose.
echo  Depending on the StorageClass's reclaim policy (most dynamic
echo  cloud StorageClasses default to Delete), the underlying cloud
echo  disks (EBS/Managed Disk/Persistent Disk) may be deleted too.
echo  This cannot be undone without a separate backup.
echo ============================================================
echo.

set /p CONFIRM="Type the namespace name (%NAMESPACE%) to confirm deletion: "
if /I not "%CONFIRM%"=="%NAMESPACE%" (
    echo Confirmation did not match - aborting, nothing deleted.
    exit /b 1
)

echo Deleting PVCs in namespace %NAMESPACE%...
kubectl delete pvc db-data-highlight tmp-highlight keycloak-data -n %NAMESPACE% --ignore-not-found

echo Done.
