# drivers/gpu/drm/imagination/Makefile of Linux 7.2.6, built out of tree:
# obj-m instead of the config symbol, the KUnit test left out, and the source
# directory on the include path for the trace header.
ccflags-y += -I$(src)

powervr-y := \
	pvr_ccb.o \
	pvr_cccb.o \
	pvr_context.o \
	pvr_device.o \
	pvr_device_info.o \
	pvr_drv.o \
	pvr_dump.o \
	pvr_free_list.o \
	pvr_fw.o \
	pvr_fw_meta.o \
	pvr_fw_mips.o \
	pvr_fw_riscv.o \
	pvr_fw_startstop.o \
	pvr_fw_trace.o \
	pvr_fw_util.o \
	pvr_gem.o \
	pvr_hwrt.o \
	pvr_job.o \
	pvr_mmu.o \
	pvr_power.o \
	pvr_queue.o \
	pvr_stream.o \
	pvr_stream_defs.o \
	pvr_sync.o \
	pvr_vm.o \
	pvr_vm_mips.o

powervr-$(CONFIG_DEBUG_FS) += \
	pvr_debugfs.o

powervr-$(CONFIG_TRACEPOINTS) += \
	pvr_trace_points.o

obj-m += powervr.o
