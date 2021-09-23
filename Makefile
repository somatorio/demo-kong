# Requer: kind, kubectl, helm, jq, awk, grep e ipcalc

URL = ${url}

.PHONY: apis

help:			## Mostra essa ajuda
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##//'

init:			## Cria o cluster usando kind, também instala metallb (para trabalhar como loadbalancer) e kong
	kind create cluster
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add metallb https://metallb.github.io/metallb
	helm repo add kong https://charts.konghq.com
	helm repo update

	helm install prometheus-grafana prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
	helm install metallb metallb/metallb -n metallb --create-namespace --set configInline.address-pools[0].name=default --set configInline.address-pools[0].protocol=layer2 --set configInline.address-pools[0].addresses[0]=$$(ipcalc $$(ipcalc $$(docker network inspect kind | jq -r '.[0].IPAM.Config[0].Subnet') | awk '/HostMax/ { print $$2 }') /24 | awk '/HostMin: /{min=$$2} /HostMax: /{max=$$2} /^$$/{print min"-"max}')
	helm install kong kong/kong -n kong -f extras/values/kong.yaml --create-namespace

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
	
clean:			## Destrói o cluster e tudo com ele ;)
	kind delete cluster

apis:			## Cria a definição inicial das apis
	@for api in $(shell ls apis/); do \
	  kubectl create -f apis/$$api; \
	done

paths-list:		## Lista paths disponíveis
	@kubectl get ing -o go-template='{{ range .items }}{{ range .spec.rules }}{{ range .http.paths }}{{.path}}{{"\n"}}{{ end }}{{ end }}{{ end }}'

admin-access:		## Cria um port-forwarding para a admin api
	kubectl -n kong port-forward $$(kubectl -n kong get svc -o name | grep 'admin$$') 8001:8001 8444:8444

grafana-access:		## Cria um port-forwarding para a interface do grafana
	kubectl -n monitoring port-forward $$(kubectl -n monitoring get svc -o name | grep 'grafana$$') 8080:80

prometheus-access:	## Cria um port-forwarding para a interface do prometheus
	kubectl -n monitoring port-forward $$(kubectl -n monitoring get svc -o name | grep 'prometheus$$') 9090:9090

consumers:		## Cria os consumidores da api (para autenticação)
	kubectl create -f extras/consumers

basic-auth:		## Ativa o plugin de basic-auth
	kubectl create -f plugins/basic-auth
	kubectl annotate -f apis/reqres/ingress.yaml konghq.com/plugins="basic-auth" --overwrite
	kubectl annotate -f apis/dog/ingress.yaml konghq.com/plugins="basic-auth" --overwrite

acl:			## Ativa o plugin de acl
	kubectl create -f plugins/acl
	kubectl annotate -f apis/reqres/ingress.yaml konghq.com/plugins="basic-auth,acl-admin" --overwrite

rate-limit:		## Ativa o plugin de rate-limit
	kubectl create -f plugins/rate-limit
	kubectl annotate -f apis/cat/ingress.yaml konghq.com/plugins="rate-limit" --overwrite

cache:			## Ativa o plugin de cache
	kubectl create -f plugins/cache
	kubectl annotate -f apis/dog/ingress.yaml konghq.com/plugins="cache" --overwrite

prometheus:		## Ativa o plugin do prometheus
	kubectl create -f plugins/prometheus

random-requests:	## Faz requisições aleatórias sem parar (use ctrl+c para parar)
	while true; do \
	  $(MAKE) $$(fgrep -h "request" $(MAKEFILE_LIST) | fgrep -v "random" | fgrep -v '#' | cut -d':' -f1 | sort -R | tail -n1); \
	  sleep 3; \
	done

cat-request:		## Faz uma requisição para o endpoint do cat api
	curl ${URL}/cat/images/search

dog-request:		## Faz uma requisição para o endpoint do dog api
	curl ${URL}/dog/breeds/image/random

reqres-request:		## Faz uma requisição para o endpoint do reqres
	curl ${URL}/reqres/users

