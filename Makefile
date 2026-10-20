EMACS = emacs

MODULE_SUFFIX := $(shell $(EMACS) -batch --eval '(princ module-file-suffix)' 2>/dev/null)
ifeq ($(MODULE_SUFFIX),)
MODULE_SUFFIX := .dylib
endif
MODULE := macos-notifications-module$(MODULE_SUFFIX)

all: $(MODULE) macos-notifications.elc

$(MODULE): macos-notifications-module.m
	clang -ObjC -fobjc-arc -Wall -Wextra -O2 -dynamiclib \
	  -mmacosx-version-min=11.0 \
	  -framework Foundation -framework UserNotifications \
	  -I. $< -o $@

macos-notifications.elc: macos-notifications.el $(MODULE)
	$(EMACS) -Q -batch -L . -f batch-byte-compile $<

test: $(MODULE) macos-notifications.elc
	$(EMACS) -Q -batch -L . -l macos-notifications-tests.el -f ert-run-tests-batch-and-exit

lint: $(MODULE)
	$(EMACS) -Q -batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile macos-notifications.el macos-notifications-tests.el
	$(EMACS) -Q -batch -L . -l macos-notifications-lint.el

clean:
	$(RM) $(MODULE) *.elc

.PHONY: all test lint clean
