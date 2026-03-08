# Gemini CLI - Project Context

## Project: Multi-Cluster Online Boutique
This project is a multi-region, multi-cluster deployment of the "Online Boutique" microservices demo on Google Cloud Platform (GCP).

## Architecture Details
- **Infrastructure:** Managed via Terraform in the root directory.
- **Regions:** `eu-west` (west) and `eu-north` (north) are used in the provided configuration.
- **Clusters:** Two GKE clusters linked into a single Istio service mesh.
- **App Source:** Located in `OnlineBoutique app/src/`.
- **Deployment:** Uses Helm charts in `OnlineBoutique app/helm-chart/`.

## Important Files
- `main.tf`: Defines the GKE clusters and Istio installation logic.
- `manifests/`: Contains regional values and Istio networking manifests.
- `OnlineBoutique app/helm-chart/`: The primary source for application deployment templates.

## Workflow Rules
1. **Infrastructure Changes:** Always verify changes in `main.tf` and related `.tf` files.
2. **App Changes:** If modifying microservices, check the respective folder in `OnlineBoutique app/src/`.
3. **Connectivity:** Cross-cluster traffic is managed via Istio East-West gateways. Refer to `manifests/expose-services.yaml` for service exposure logic.
4. **Context Management:** Use `.geminiignore` to keep the context clean of build artifacts and large images.
