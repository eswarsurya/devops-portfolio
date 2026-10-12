CLUSTER := gitops-lab
ARGOCD_VERSION := v2.13.1

.PHONY: up argocd bootstrap ui grafana lint drain-test down

up:            ## Create the 3-node kind cluster
	kind create cluster --config kind/cluster.yaml

argocd:        ## Install Argo CD and wait for it
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

bootstrap:     ## Hand control to git: apply the root app-of-apps
	kubectl apply -f argocd/root-app.yaml

ui:            ## Argo CD UI on https://localhost:8080 (user: admin)
	@echo "password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

grafana:       ## Grafana on http://localhost:3000 (admin / change-me-locally)
	kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

lint:          ## Same checks CI runs
	helm lint charts/incident-api -f charts/incident-api/values-prod.yaml
	helm template demo charts/incident-api -f charts/incident-api/values-prod.yaml \
	  | kubeconform -strict -summary -skip ServiceMonitor

drain-test:    ## Prove the PDB works: drain a worker and watch pods move
	kubectl drain $(CLUSTER)-worker --ignore-daemonsets --delete-emptydir-data
	kubectl get pods -A -o wide | grep incident-api
	kubectl uncordon $(CLUSTER)-worker

down:          ## Delete everything
	kind delete cluster --name $(CLUSTER)
