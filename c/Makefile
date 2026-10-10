CFLAGS ?= -O2 -Wall -Wextra
all: phone mjpeg-tap
phone: phone.c
	$(CC) $(CFLAGS) -o $@ $<
mjpeg-tap: mjpeg-tap.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f phone mjpeg-tap
