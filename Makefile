PYTHON ?= python3
.PHONY: build run demo test install uninstall disable package
build:
	$(PYTHON) scripts/build.py
run: build
	open build/CompanionHover.app
demo:
	$(PYTHON) scripts/build.py --demo
	open build/CompanionHoverDemo.app --args --demo
install: build
	$(PYTHON) scripts/install.py
uninstall:
	$(PYTHON) scripts/install.py --uninstall
disable:
	$(PYTHON) scripts/install.py --disable
test:
	$(PYTHON) scripts/test.py
package:
	$(PYTHON) scripts/package.py --arch universal
