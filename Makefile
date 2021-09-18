# Requer: kind, kubectl, helm, jq, awk, grep e ipcalc

.PHONY: apis

help:		## Mostra essa ajuda
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##//'

init:		## Cria o cluster usando kind, também instala metallb (para trabalhar como loadbalancer) e kong
	kind create cluster
	helm repo add metallb https://metallb.github.io/metallb
	helm repo add kong https://charts.konghq.com
	helm repo update

	helm install metallb metallb/metallb -n metallb --create-namespace --set configInline.address-pools[0].name=default --set configInline.address-pools[0].protocol=layer2 --set configInline.address-pools[0].addresses[0]=$$(ipcalc $$(ipcalc $$(docker network inspect kind | jq -r '.[0].IPAM.Config[0].Subnet') | awk '/HostMax/ { print $$2 }') /24 | awk '/HostMin: /{min=$$2} /HostMax: /{max=$$2} /^$$/{print min"-"max}')
	helm install kong/kong --generate-name --set ingressController.installCRDs=false -n kong --create-namespace --set admin.enabled="true"

	@# Claramente minhas skills em Makefile são horríveis =p
	@SVCKONG=$$(kubectl -n kong get svc -o name | grep 'proxy'); \
	echo "Esperando o service do kong receber o ip"; \
	while [ "$$(kubectl -n kong get $$SVCKONG -o json | jq -Mr '.status.loadBalancer.ingress[0].ip')" = "null" ]; do \
	  sleep 5; \
	done; \
	IPKONG=$$(kubectl -n kong get $${SVCKONG} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
	PORTKONG=$$(kubectl -n kong get $${SVCKONG} -o jsonpath='{.spec.ports[0].port}'); \
	echo "Esperando o Kong estar disponível em $${IPKONG}:$${PORTKONG}"; \
	while ! curl -s $${IPKONG}:$${PORTKONG} > /dev/null; do \
	   sleep 5; \
	done; \
	echo "Pronto :)" ; \
	echo "" ; \
	echo "Para facilitar o uso faça uma variável com o comando:"; \
	echo "export url=$${IPKONG}:$${PORTKONG}"
	
clean:		## Destrói o cluster e tudo com ele ;)
	kind delete cluster

apis:		## Cria a definição inicial das apis
	@for api in $(shell ls apis/); do \
	  kubectl create -f apis/$$api; \
	done

paths-list:	## Lista paths disponíveis
	@kubectl get ing -o go-template='{{ range .items }}{{ range .spec.rules }}{{ range .http.paths }}{{.path}}{{"\n"}}{{ end }}{{ end }}{{ end }}'

consumers:
	kubectl create -f extras/consumers

basic-auth:
	kubectl create -f plugins/basic-auth
	kubectl annotate -f apis/reqres/ingress.yaml konghq.com/plugins="basic-auth" --overwrite
	kubectl annotate -f apis/dog/ingress.yaml konghq.com/plugins="basic-auth" --overwrite

acl:
	kubectl create -f plugins/acl
	kubectl annotate -f apis/reqres/ingress.yaml konghq.com/plugins="basic-auth,acl-admin" --overwrite

rate-limit:
	kubectl create -f plugins/rate-limit
	kubectl annotate -f apis/cat/ingress.yaml konghq.com/plugins="rate-limit" --overwrite