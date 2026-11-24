# nomount.c includes overlayfs/ovl_entry.h when OverlayFS is enabled.
# Resolve that header from the fs/ directory while keeping the engine isolated
# in its own Kbuild directory.
ccflags-y += -I$(srctree)/fs

obj-y += nomount.o
