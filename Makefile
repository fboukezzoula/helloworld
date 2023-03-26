VERSION_FILE := version
VERSION := $(shell cat ${VERSION_FILE})
IMAGE_REPO := $(ACR_NAME).azurecr.io/poc-helloworld

.PHONY: build
build:
	docker build --build-arg AZURE_STORAGE_CONNECTION_STRING=$(AZURE_STORAGE_CONNECTION_STRING) --build-arg AZURE_STORAGE_CONTAINER_NAME=$(AZURE_STORAGE_CONTAINER_NAME) -t $(IMAGE_REPO):$(VERSION)-$(SHA) .

.PHONY: registry-login
registry-login:
	@az login \
		--service-principal \
		--username $(SERVICE_PRINCIPAL_APP_ID) \
		--password $(SERVICE_PRINCIPAL_SECRET) \
		--tenant $(SERVICE_PRINCIPAL_TENANT)
	@az acr login --name $(ACR_NAME)

.PHONY: push
push:
	docker push $(IMAGE_REPO):$(VERSION)-$(SHA)

.PHONY: deploy
deploy:
	sed 's/SHA/$(SHA)/g; s/VERSION/$(VERSION)/g' ./deployment.yaml | \
		kubectl apply -f -