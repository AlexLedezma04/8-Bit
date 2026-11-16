# Build.
CC := cc
CFLAGS ?= -O2

all: main

main: main.c
	$(CC) $(CFLAGS) -o $@ $<

ifeq ($(OS),Windows_NT)
EXE := .exe
endif
