PLAYBOOK_INSTALL := install.yml
PLAYBOOK_UNINSTALL := uninstall.yml

.PHONY: install clean remove uninstall test test-playbooks install-both uninstall-both dataset-build

VENV ?= .venv
S2T_USER ?=
S2T_USERS ?= work ilja
DATASET_INPUT ?= data/raw
DATASET_OUTPUT ?= data/dataset
DATASET_TEST_RATIO ?= 0.1
DATASET_JOBS ?= 4
DATASET_SEED ?= 42

ANSIBLE_PLAYBOOK := $(if $(wildcard $(VENV)/bin/ansible-playbook),$(abspath $(VENV))/bin/ansible-playbook,ansible-playbook)
MOLECULE := $(if $(wildcard $(VENV)/bin/molecule),$(abspath $(VENV))/bin/molecule,molecule)
ANSIBLE_PYTHON_INTERPRETER := $(if $(wildcard $(VENV)/bin/python),$(abspath $(VENV))/bin/python,)
PYTHON := $(if $(wildcard $(VENV)/bin/python),$(abspath $(VENV))/bin/python,python3)
ANSIBLE_EXTRA_VARS := $(if $(strip $(S2T_USER)),-e s2t_target_user=$(S2T_USER),)

install:
	@echo "Installing S2T (recommended setup) using Ansible..."
	ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_INSTALL) $(ANSIBLE_EXTRA_VARS)

clean: remove

remove:
	@echo "Uninstalling S2T Role..."
	ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_UNINSTALL) $(ANSIBLE_EXTRA_VARS)

uninstall: remove

test:
	@echo "Running Molecule tests (requires docker & molecule)..."
	@echo "Running playbook checks..."
	VENV="$(VENV)" ./scripts/check_playbooks.sh
	cd s2t-role && PATH="$(abspath $(VENV))/bin:$$PATH" $(MOLECULE) test

test-playbooks:
	@echo "Running playbook checks..."
	VENV="$(VENV)" ./scripts/check_playbooks.sh

install-both:
	@echo "Installing S2T for users: $(S2T_USERS)"
	@set -e; \
	for u in $(S2T_USERS); do \
		echo "==> install for $$u"; \
		ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_INSTALL) -e s2t_target_user=$$u; \
	done

uninstall-both:
	@echo "Uninstalling S2T for users: $(S2T_USERS)"
	@set -e; \
	for u in $(S2T_USERS); do \
		echo "==> uninstall for $$u"; \
		ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_UNINSTALL) -e s2t_target_user=$$u; \
	done

dataset-build:
	@echo "Building dataset from $(DATASET_INPUT) -> $(DATASET_OUTPUT)"
	$(PYTHON) scripts/build_dataset.py \
		--input-dir "$(DATASET_INPUT)" \
		--output-dir "$(DATASET_OUTPUT)" \
		--test-ratio "$(DATASET_TEST_RATIO)" \
		--jobs "$(DATASET_JOBS)" \
		--seed "$(DATASET_SEED)"
