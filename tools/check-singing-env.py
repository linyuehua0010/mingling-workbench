"""验证真实 CUDA 运算；使用脚本文件避免 Windows PowerShell 丢失 -c 内部引号。"""
import argparse
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
args = parser.parse_args()
sys.path.insert(0, args.source)
import torch
from cli.inference import build_model

if not torch.cuda.is_available():
    raise RuntimeError('CUDA 不可用，请检查显卡驱动与独立唱歌环境')
value = torch.ones(8, device='cuda').sum().item()
if value != 8:
    raise RuntimeError('CUDA 计算结果异常')
print('torch=' + torch.__version__)
print('device=' + torch.cuda.get_device_name(0))
print('capability=' + str(torch.cuda.get_device_capability(0)))
print('cuda_kernel_ok=1')
