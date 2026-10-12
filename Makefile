# SPDX-License-Identifier: 0BSD

.PHONY: install uninstall test clean help

help:
	@echo "make install    install the fold / tablet-mode stack (elevates itself)"
	@echo "make uninstall  remove it and restore the distribution package"
	@echo "make test       install into a temporary DESTDIR and check the layout"

install:
	./install

uninstall:
	./uninstall

# Exercises the file placement without touching the running system.
test:
	rm -rf /tmp/chuwi-display-test
	IIO_BINARY="$$(pwd)/files/minibook-rotation-fix.py" \
		DESTDIR=/tmp/chuwi-display-test ./install
	find /tmp/chuwi-display-test -type f -o -type l | sort | sed "s|/tmp/chuwi-display-test||"
	rm -rf /tmp/chuwi-display-test

clean:
	rm -rf /tmp/chuwi-display-test
