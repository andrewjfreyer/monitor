
from bt_proximity import BluetoothRSSI
import time
import sys

BT_ADDR = ''  # You can put your Bluetooth address here
NUM_LOOP = 1
rssilist = []

def print_usage():
    print(
        "Usage: python rssi.py <bluetooth-address> [number-of-requests]")


def main():
    if len(sys.argv) > 1:
        addr = sys.argv[1]
    elif BT_ADDR:
        addr = BT_ADDR
    else:
        print_usage()
        return
    if len(sys.argv) == 3:
        num = int(sys.argv[2])
    else:
        num = NUM_LOOP
    btrssi = BluetoothRSSI(addr=addr)
    for i in range(0, num):
        rssi = btrssi.request_rssi()
        rssilist.append(99) if rssi == None else rssilist.append(abs(int(rssi[0])))
        time.sleep(1)
    print(min(rssilist))


if __name__ == '__main__':
    main()
