"""Synthetic packets only: no network access, real captures or nft mutations."""
import argparse
import ipaddress
import pathlib
import struct
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--lua', default='lua')
args, remaining = parser.parse_known_args()


def client_hello(host):
    name = host.encode('ascii')
    entry = b'\0' + struct.pack('!H', len(name)) + name
    sni = struct.pack('!H', len(entry)) + entry
    extensions = struct.pack('!HH', 0, len(sni)) + sni
    body = b'\x03\x03' + bytes(32) + b'\0\0\x02\xc0\x13\x01\0' + struct.pack('!H', len(extensions)) + extensions
    handshake = b'\x01' + len(body).to_bytes(3, 'big') + body
    return b'\x16\x03\x01' + struct.pack('!H', len(handshake)) + handshake


def frame(payload, *, ipv4=False, vlan=False, dlt=1, seq=100, port=443):
    tcp = struct.pack('!HHIIBBHHH', 49152, port, seq, 0, 0x50, 0x18, 65535, 0, 0) + payload
    if ipv4:
        packet = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20+len(tcp), 0, 0, 64, 6, 0, b'\xc0\x00\x02\x01', b'\xc0\x00\x02\x02') + tcp
        ether = 0x0800
    else:
        packet = struct.pack('!IHBB16s16s', 0x60000000, len(tcp), 6, 64, ipaddress.IPv6Address('2001:db8::1').packed, ipaddress.IPv6Address('2001:db8::2').packed) + tcp
        ether = 0x86dd
    if dlt == 276:
        return struct.pack('!HHIHBB8s', ether, 0, 1, 1, 0, 6, bytes(8)) + packet
    if dlt == 113:
        return struct.pack('!HHH8sH', 0, 1, 6, bytes(8), ether) + packet
    prefix = bytes(12)
    if vlan:
        return prefix + struct.pack('!HHH', 0x8100, 1, ether) + packet
    return prefix + struct.pack('!H', ether) + packet


def pcap(frames, *, dlt=1, little=True):
    order = '<' if little else '>'
    result = struct.pack(order+'IHHIIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, dlt)
    for index, packet in enumerate(frames):
        result += struct.pack(order+'IIII', index+1, 0, len(packet), len(packet)) + packet
    return result


class LearnerTests(unittest.TestCase):
    def run_packets(self, packets, **options):
        result = subprocess.run([args.lua, str(ROOT/'files/usr/libexec/xhs-ipv4-learn.lua'), '--dry-run', str(ROOT/'files/etc/xhs-ipv4/domains')], input=pcap(packets, **options), capture_output=True, check=True)
        return result.stdout.decode().splitlines()

    def test_tls(self):
        self.assertEqual(self.run_packets([frame(client_hello('sns-na-i4.xhscdn.com'))]), ['sns-na-i4.xhscdn.com 2001:db8:0:0:0:0:0:2'])

    def test_suffix_boundary(self):
        for host in ['xhscdn.com.evil.example', 'evilxhscdn.com', 'example.com']:
            with self.subTest(host=host):
                self.assertEqual(self.run_packets([frame(client_hello(host))]), [])

    def test_case_and_apex(self):
        self.assertTrue(self.run_packets([frame(client_hello('XHScdn.COM'))]))
        self.assertTrue(self.run_packets([frame(client_hello('xhscdn.com'))]))

    def test_ipv4_ignored(self):
        self.assertEqual(self.run_packets([frame(client_hello('xhscdn.com'), ipv4=True)]), [])

    def test_wrong_port_ignored(self):
        self.assertEqual(self.run_packets([frame(client_hello('xhscdn.com'), port=8443)]), [])

    def test_http_host(self):
        self.assertTrue(self.run_packets([frame(b'GET /synthetic HTTP/1.1\r\nHost: sns-na-i2.xhscdn.com:80\r\n\r\n', port=80)]))

    def test_contiguous_tcp_segments(self):
        hello = client_hello('sns-na-i4.xhscdn.com')
        self.assertTrue(self.run_packets([frame(hello[:55]), frame(hello[55:], seq=155)]))

    def test_missing_tcp_segment_is_not_guessed(self):
        hello = client_hello('sns-na-i4.xhscdn.com')
        self.assertEqual(self.run_packets([frame(hello[:55]), frame(hello[60:], seq=160)]), [])

    def test_link_formats_and_endianness(self):
        for dlt in [1, 113, 276]:
            for little in [True, False]:
                with self.subTest(dlt=dlt, little=little):
                    self.assertTrue(self.run_packets([frame(client_hello('xhscdn.com'), dlt=dlt)], dlt=dlt, little=little))

    def test_vlan(self):
        self.assertTrue(self.run_packets([frame(client_hello('xhscdn.com'), vlan=True)]))

    def test_malformed_tls_does_not_learn(self):
        bad = b'\x16\x03\x01\xff\xff\x01'+bytes(100)
        self.assertEqual(self.run_packets([frame(bad)]), [])


if __name__ == '__main__':
    unittest.main(argv=[__file__]+remaining)
