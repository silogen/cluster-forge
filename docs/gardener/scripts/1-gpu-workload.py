import os, time, torch

print("=" * 64)
print("torch           :", torch.__version__)
print("ROCm/HIP version:", getattr(torch.version, "hip", None))
print("GPU available   :", torch.cuda.is_available())
n = torch.cuda.device_count()
print("device count    :", n)
for i in range(n):
    p = torch.cuda.get_device_properties(i)
    print(f"  [{i}] {p.name}  arch={getattr(p,'gcnArchName','?')}  "
          f"VRAM={p.total_memory/2**30:.1f} GiB  CUs={p.multi_processor_count}")
print("=" * 64, flush=True)

if not torch.cuda.is_available():
    raise SystemExit("no GPU visible to the ROCm runtime")

dev = torch.device("cuda:0")
N = int(os.environ.get("N", 8192))
SECS = int(os.environ.get("SECS", 120))

# allocate a few GB so VRAM usage is clearly visible from the host sysfs
a = torch.randn(N, N, device=dev, dtype=torch.float32)
b = torch.randn(N, N, device=dev, dtype=torch.float32)
ballast = torch.empty(int(8e9 // 4), device=dev, dtype=torch.float32)  # ~8 GB
torch.cuda.synchronize()
print(f"allocated: {torch.cuda.memory_allocated(dev)/2**30:.1f} GiB on device 0", flush=True)

flop_per_iter = 2.0 * N ** 3
t_end = time.time() + SECS
it = 0
t0 = time.time()
last = t0
while time.time() < t_end:
    c = a @ b
    it += 1
    if it % 20 == 0:
        torch.cuda.synchronize()
        now = time.time()
        tflops = 20 * flop_per_iter / (now - last) / 1e12
        print(f"  t+{now-t0:6.1f}s  iters={it:6d}  {tflops:7.1f} TFLOP/s fp32  "
              f"checksum={float(c[0,0]):.4f}", flush=True)
        last = now
torch.cuda.synchronize()
total = time.time() - t0
print("=" * 64)
print(f"DONE  {it} matmuls of {N}x{N} in {total:.1f}s  "
      f"avg {it*flop_per_iter/total/1e12:.1f} TFLOP/s fp32")
print("peak VRAM allocated: %.1f GiB" % (torch.cuda.max_memory_allocated(dev)/2**30))
print("=" * 64)
