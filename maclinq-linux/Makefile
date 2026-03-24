CC      = gcc
CFLAGS  = -Wall -Wextra -O2
TARGET  = maclinq-receiver
SRCS    = main.c uinput_device.c protocol.c server.c
OBJS    = $(SRCS:.c=.o)
TEST_TARGET = protocol-test

.PHONY: all clean install test

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

$(TEST_TARGET): tests/protocol_test.c protocol.c protocol.h
	$(CC) $(CFLAGS) -I. -o $@ tests/protocol_test.c protocol.c

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

test: $(TEST_TARGET)
	./$(TEST_TARGET)

clean:
	rm -f $(OBJS) $(TARGET) $(TEST_TARGET)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)
