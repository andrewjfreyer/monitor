from bt_proximity import BluetoothRSSI
import time
import sys

BT_ADDR = ''  # You can put your Bluetooth address here
NUM_LOOP = 1

def print_usage():
    print "Usage: python test_address.py <bluetooth-address> [number-of-requests]"


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
        print btrssi.get_rssi()
        time.sleep(1)


if __name__ == '__main__':
    main()
