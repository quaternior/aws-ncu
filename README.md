# aws-ncu

```
sudo su -
source enable-root-ssh.sh
```

```
nvcc -O3 -arch=sm_86 -lineinfo vectoradd.cu -o vecadd
./vecadd            # default N = 2^24
# Also test on remote machine
```