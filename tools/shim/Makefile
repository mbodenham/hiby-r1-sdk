MUSL_TC = ../vendors/mipsel-linux-musl-cross/bin/mipsel-linux-musl-

shim.so: shim.c
	$(MUSL_TC)gcc -shared -static -fPIC -O2 -nostdlib -march=mips32r2 -Wl,-Bsymbolic-functions,-Bsymbolic -mtune=mips32r2 -o $@ $<
