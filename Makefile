PLAYBOOK_INSTALL := install.yml
PLAYBOOK_UNINSTALL := uninstall.yml

.PHONY: install clean remove uninstall test test-playbooks install-both uninstall-both dataset-build deploy-gcp-l4 install-gcp-l4-keepalive uninstall-gcp-l4-keepalive rust-deploy rust-restart rust-provider-google rust-provider-local rust-provider-aws rust-logrotate-install rust-logs

VENV ?= .venv
S2T_USER ?=
S2T_USERS ?= work ilja
DATASET_INPUT ?= data/raw
DATASET_OUTPUT ?= data/dataset
DATASET_TEST_RATIO ?= 0.1
DATASET_JOBS ?= 4
DATASET_SEED ?= 42
PROJECT_ID ?=
REGION ?= europe-north1
SERVICE_NAME ?= whisper-l4
RUST_BIN ?= /home/ilja/.local/bin/s2t-core-rust
RUST_PKG_CONFIG_PATH ?= /usr/lib/x86_64-linux-gnu/pkgconfig
S2T_ENV_FILE ?= $(HOME)/.config/s2t/s2t.env
S2T_LOGROTATE_MAX_BYTES ?= 10485760
S2T_LOGROTATE_KEEP ?= 5

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

deploy-gcp-l4:
	@if [ -z "$(PROJECT_ID)" ]; then echo "PROJECT_ID is required, e.g. make deploy-gcp-l4 PROJECT_ID=my-project"; exit 1; fi
	PROJECT_ID="$(PROJECT_ID)" REGION="$(REGION)" SERVICE_NAME="$(SERVICE_NAME)" ./whisper-l4/deploy_cloud_run.sh

install-gcp-l4-keepalive:
	sudo ./whisper-l4/keepalive/install_keepalive.sh

uninstall-gcp-l4-keepalive:
	sudo ./whisper-l4/keepalive/uninstall_keepalive.sh

rust-deploy:
	@echo "Building and deploying Rust core only (no legacy service restarts)..."
	cd s2t-core-rust && PKG_CONFIG_PATH="$(RUST_PKG_CONFIG_PATH)" cargo build --release
	install -m 0755 s2t-core-rust/target/release/s2t-core-rust "$(RUST_BIN)"
	systemctl --user restart s2t-rust.service
	systemctl --user status s2t-rust.service --no-pager -n 20

rust-restart:
	@echo "Restarting rust service..."
	systemctl --user restart s2t-rust.service
	systemctl --user status s2t-rust.service --no-pager -n 20

rust-provider-google:
	@echo "Switching provider to GOOGLE in $(S2T_ENV_FILE) with full rust deploy..."
	@mkdir -p "$$(dirname "$(S2T_ENV_FILE)")"
	@touch "$(S2T_ENV_FILE)"
	@set -e; \
	set_kv() { \
		key="$$1"; val="$$2"; file="$(S2T_ENV_FILE)"; \
		if grep -q "^$${key}=" "$$file"; then \
			sed -i "s#^$${key}=.*#$${key}=$${val}#" "$$file"; \
		else \
			echo "$${key}=$${val}" >> "$$file"; \
		fi; \
	}; \
	unset_kv() { key="$$1"; file="$(S2T_ENV_FILE)"; sed -i "/^$${key}=.*/d" "$$file"; }; \
	set_kv S2T_ASR_PROVIDER google; \
	unset_kv S2T_LOCAL_STREAM_STEP_MS; \
	unset_kv S2T_LOCAL_STREAM_WINDOW_MS
	@timeout 20s systemctl --user stop s2t-whisper.service || true
	@systemctl --user is-active --quiet s2t-whisper.service && systemctl --user kill --signal=SIGKILL s2t-whisper.service || true
	@pid="$$(systemctl --user show -p MainPID --value s2t-whisper.service 2>/dev/null || true)"; \
	if [ -n "$$pid" ] && [ "$$pid" != "0" ]; then kill -9 "$$pid" 2>/dev/null || true; fi
	@sleep 1
	$(MAKE) rust-deploy
	@echo "GPU after switch (whisper should be unloaded):"
	@nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader || true

rust-provider-local:
	@echo "Switching provider to LOCAL in $(S2T_ENV_FILE) with full rust deploy..."
	@mkdir -p "$$(dirname "$(S2T_ENV_FILE)")"
	@touch "$(S2T_ENV_FILE)"
	@set -e; \
	set_kv() { \
		key="$$1"; val="$$2"; file="$(S2T_ENV_FILE)"; \
		if grep -q "^$${key}=" "$$file"; then \
			sed -i "s#^$${key}=.*#$${key}=$${val}#" "$$file"; \
		else \
			echo "$${key}=$${val}" >> "$$file"; \
		fi; \
	}; \
		unset_kv() { key="$$1"; file="$(S2T_ENV_FILE)"; sed -i "/^$${key}=.*/d" "$$file"; }; \
		set_kv S2T_ASR_PROVIDER local; \
		set_kv S2T_MODEL_PATH /home/ilja/.local/share/s2t/ggml-small.bin; \
		set_kv S2T_LANG ru; \
		set_kv S2T_LOCAL_REQUEST_LANGUAGE ru; \
		set_kv S2T_LOCAL_STREAMING 1; \
		set_kv S2T_LOCAL_STREAM_BIN /etc/s2t/result/bin/whisper-stream; \
		set_kv S2T_LOCAL_STREAM_STEP_MS 600; \
		set_kv S2T_LOCAL_STREAM_LENGTH_MS 2400; \
		set_kv S2T_LOCAL_STREAM_KEEP_MS 120; \
		set_kv S2T_LOCAL_STREAM_FLUSH_MS 700; \
		set_kv S2T_LOCAL_STREAM_CAPTURE_ID 0; \
		set_kv S2T_LOCAL_STREAM_KEEP_CONTEXT 1; \
		set_kv S2T_NO_SPEECH_THOLD 0.35; \
		set_kv S2T_BEAM_SIZE -1; \
		set_kv S2T_BEST_OF 1; \
		set_kv S2T_NO_FALLBACK 1; \
		unset_kv S2T_LOCAL_STREAM_WINDOW_MS
	@set -e; \
	echo "Ensuring s2t-whisper.service is running for local provider..."; \
	systemctl --user restart s2t-whisper.service; \
	systemctl --user status s2t-whisper.service --no-pager -n 20; \
	echo "Waiting for whisper-server to become ready on 127.0.0.1:9788..."; \
	ready=0; \
	for i in $$(seq 1 90); do \
		if curl -sS --max-time 1 "http://127.0.0.1:9788/" >/dev/null 2>&1; then ready=1; break; fi; \
		sleep 1; \
	done; \
	if [ "$$ready" != "1" ]; then \
		echo "ERROR: whisper-server is not ready on 127.0.0.1:9788"; \
		systemctl --user status s2t-whisper.service --no-pager -n 60 || true; \
		exit 1; \
	fi
	$(MAKE) rust-deploy
	@echo "GPU after switch (whisper should be loaded):"
	@nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader || true

rust-provider-aws:
	@echo "Switching provider to AWS in $(S2T_ENV_FILE) with full rust deploy..."
	@mkdir -p "$$(dirname "$(S2T_ENV_FILE)")"
	@touch "$(S2T_ENV_FILE)"
	@set -e; \
	set_kv() { \
		key="$$1"; val="$$2"; file="$(S2T_ENV_FILE)"; \
		if grep -q "^$${key}=" "$$file"; then \
			sed -i "s#^$${key}=.*#$${key}=$${val}#" "$$file"; \
		else \
			echo "$${key}=$${val}" >> "$$file"; \
		fi; \
	}; \
	unset_kv() { key="$$1"; file="$(S2T_ENV_FILE)"; sed -i "/^$${key}=.*/d" "$$file"; }; \
	set_kv S2T_ASR_PROVIDER aws; \
	set_kv S2T_AWS_IDENTIFY_LANGUAGE 1; \
	set_kv S2T_AWS_IDENTIFY_MODE multiple; \
	set_kv S2T_AWS_LANGUAGE_OPTIONS ru-RU,en-US; \
	set_kv S2T_AWS_PREFERRED_LANGUAGE ru-RU; \
	set_kv S2T_AWS_MEDIA_ENCODING pcm; \
	unset_kv S2T_LOCAL_STREAM_STEP_MS; \
	unset_kv S2T_LOCAL_STREAM_WINDOW_MS
	@timeout 20s systemctl --user stop s2t-whisper.service || true
	@systemctl --user is-active --quiet s2t-whisper.service && systemctl --user kill --signal=SIGKILL s2t-whisper.service || true
	@pid="$$(systemctl --user show -p MainPID --value s2t-whisper.service 2>/dev/null || true)"; \
	if [ -n "$$pid" ] && [ "$$pid" != "0" ]; then kill -9 "$$pid" 2>/dev/null || true; fi
	@sleep 1
	$(MAKE) rust-deploy
	@echo "GPU after switch (whisper should be unloaded):"
	@nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader || true

rust-logrotate-install:
	@echo "Installing user log rotation for /run/user/$$(id -u)/s2t/s2t.log ..."
	install -m 0755 scripts/s2t_logrotate.sh "$(HOME)/.local/bin/s2t-logrotate.sh"
	mkdir -p "$(HOME)/.config/systemd/user"
	install -m 0644 systemd-user/s2t-logrotate.service "$(HOME)/.config/systemd/user/s2t-logrotate.service"
	install -m 0644 systemd-user/s2t-logrotate.timer "$(HOME)/.config/systemd/user/s2t-logrotate.timer"
	systemctl --user daemon-reload
	systemctl --user set-environment S2T_LOGROTATE_MAX_BYTES="$(S2T_LOGROTATE_MAX_BYTES)"
	systemctl --user set-environment S2T_LOGROTATE_KEEP="$(S2T_LOGROTATE_KEEP)"
	systemctl --user enable --now s2t-logrotate.timer
	systemctl --user start s2t-logrotate.service
	systemctl --user status s2t-logrotate.timer --no-pager -n 20
	@echo "Logrotate installed: max_bytes=$(S2T_LOGROTATE_MAX_BYTES), keep=$(S2T_LOGROTATE_KEEP)"

rust-logs:
	@echo "Tailing Rust core log..."
	tail -f /run/user/$$(id -u)/s2t/s2t.log
