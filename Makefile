# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

.PHONY: build clean dev dev-with-widgets help install js sdist system-test-local system-test-remote test

PYTHON?=python3

REPO:=jupyter/pyspark-notebook:8015c88c4b11
BOWER_REPO:=jupyter/pyspark-notebook-bower:8015c88c4b11
PYTHON2_SETUP:=source activate python2

define EXT_DEV_SETUP
	jupyter nbextension install --py jupyter_dashboards --sys-prefix --symlink && \
	jupyter nbextension enable --py jupyter_dashboards --sys-prefix
endef

help:
# http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

build: ## Build the dev Docker image
	@-docker rm -f bower-build
	@docker run -it --user root --name bower-build \
		$(REPO) bash -c 'apt-get update && \
		apt-get install -y curl && \
		curl --silent --location https://deb.nodesource.com/setup_0.12 | sudo bash - && \
		apt-get install --yes nodejs && \
		npm install -g bower'
	@docker commit bower-build $(BOWER_REPO)
	@-docker rm -f bower-build

clean: ## Clean source tree
	@-rm -rf dist
	@-rm -rf *.egg-info
	@-rm -rf etc/notebooks/local_dashboards
	@-rm -rf node_modules
	@-rm -rf jupyter_dashboards/nbextension/notebook/bower_components
	@-find . -name __pycache__ -exec rm -fr {} \;

js: ## Build Javascript components
# Run as root to appease travis
	@docker run -it --rm \
		--user root \
		-v `pwd`:/src \
		$(BOWER_REPO) bash -c 'cd /src && npm install && npm run bower'

dev: dev-$(PYTHON) ## Start notebook server in a container with source mounted

dev-python2: LANG_SETUP_CMD:=$(PYTHON2_SETUP) && python --version
dev-python2: EXTENSION_DIR:=/opt/conda/envs/python2/lib/python2.7/site-packages/jupyter_dashboards
dev-python2: _dev

dev-python3: LANG_SETUP_CMD:=python --version
dev-python3: EXTENSION_DIR:=/opt/conda/lib/python3.5/site-packages/jupyter_dashboards
dev-python3: _dev

_dev: OPTIONS?=--rm -it
_dev: SERVER_NAME?=jupyter_dashboards_dev_server
_dev: CMD?=start-notebook.sh
_dev:
	@docker run $(OPTIONS) --name $(SERVER_NAME) \
		-p 9500:8888 \
		-v `pwd`/jupyter_dashboards:$(EXTENSION_DIR) \
		-v `pwd`/scripts/jupyter-dashboards:/usr/local/bin/jupyter-dashboards \
		-v `pwd`/etc/notebooks:/home/jovyan/work \
		$(REPO) bash -c '$(LANG_SETUP_CMD) && $(EXT_DEV_SETUP) && $(CMD)'

dev-with-widgets: dev-with-widgets-$(PYTHON) ## Same as dev but w/ declarative widgets enabled

dev-with-widgets-python2: LANG_SETUP_CMD?=$(PYTHON2_SETUP) && python --version
dev-with-widgets-python2: EXTENSION_DIR:=/opt/conda/envs/python2/lib/python2.7/site-packages/jupyter_dashboards
dev-with-widgets-python2: _dev-with-widgets

dev-with-widgets-python3: LANG_SETUP_CMD?=python --version
dev-with-widgets-python3: EXTENSION_DIR:=/opt/conda/lib/python3.5/site-packages/jupyter_dashboards
dev-with-widgets-python3: _dev-with-widgets

_dev-with-widgets: CMD?=start-notebook.sh
_dev-with-widgets:
	@docker run -it --rm \
		-p 9500:8888 \
		--user jovyan \
		-v `pwd`/jupyter_dashboards:$(EXTENSION_DIR) \
		-v `pwd`/scripts/jupyter-dashboards:/usr/local/bin/jupyter-dashboards \
		-v `pwd`/etc/notebooks:/home/jovyan/work \
		$(BOWER_REPO) bash -c '$(LANG_SETUP_CMD) && $(EXT_DEV_SETUP) && \
			pip install jupyter_declarativewidgets && \
			jupyter declarativewidgets quick-setup --sys-prefix && \
			$(CMD)'

install: install-$(PYTHON) ## Install and activate the sdist package in the container

install-python2: SETUP_CMD=$(PYTHON2_SETUP) && python --version
install-python2: _install

install-python3: SETUP_CMD=python --version
install-python3: _install

_install: CMD?=exit
_install:
	@docker run -it --rm \
		-v `pwd`:/src \
		$(REPO) bash -c '$(SETUP_CMD) && cd /src/dist && \
			pip install --no-binary :all: $$(ls -1 *.tar.gz | tail -n 1) && \
			jupyter dashboards quick-setup --sys-prefix && \
			$(CMD)'

sdist: js ## Build a source distribution in dist/
# Run as root to appease travis
	@docker run -it --rm \
		--user root \
		-v `pwd`:/src \
		$(REPO) bash -c 'cp -r /src /tmp/src && \
			cd /tmp/src && \
			python setup.py sdist $(POST_SDIST) && \
			cp -r dist /src'

release: POST_SDIST=register upload
release: sdist ## Package and release to PyPI

_system-test-local-setup:
# Check if deps are installed when running locally
	@which chromedriver || (echo "chromedriver not found (brew install chromedriver)"; exit 1)
	@which selenium-server || (echo "selenium-server not found (brew install selenium-server-standalone)"; exit 1)
	@cd system-test/bin; ./run-selenium.sh

_system-test-local-teardown:
	@-cd system-test/bin; ./kill-selenium.sh

system-test-local: TEST_SERVER?=192.168.99.1:4444
system-test-local: BASEURL?=http://192.168.99.100:9500
system-test-local: TEST_TYPE?=local
system-test-local: _system-test-local-setup _system-test _system-test-local-teardown ## Run selenium tests locally

system-test-remote: TEST_TYPE?=remote
system-test-remote: BASEURL?=http://127.0.0.1:9500
system-test-remote: TEST_SERVER?=ondemand.saucelabs.com
system-test-remote: _system-test ## Run selenium tests on Sauce Labs using SAUCE_USERNAME and SAUCE_ACCESS_KEY

_system-test: SERVER_NAME?=jupyter_dashboards_integration_test_server
_system-test: CMD?=bash -c 'cd /src; npm run system-test -- --baseurl $(BASEURL) --server $(TEST_SERVER) --test-type $(TEST_TYPE)'
_system-test:
	-@docker rm -f $(SERVER_NAME)
	@OPTIONS=-d SERVER_NAME=$(SERVER_NAME) $(MAKE) dev
	@echo 'Waiting 30 seconds for server to start...'
	@sleep 30
	@echo 'Running system integration tests...'
	@docker run --rm -it \
		--net=host \
		--user jovyan \
		-e SAUCE_USERNAME=$(SAUCE_USERNAME) \
		-e SAUCE_ACCESS_KEY=$(SAUCE_ACCESS_KEY) \
		-e TRAVIS_JOB_NUMBER=$(TRAVIS_JOB_NUMBER) \
		-v `pwd`:/src \
		$(BOWER_REPO) $(CMD)
	-@docker rm -f $(SERVER_NAME)
