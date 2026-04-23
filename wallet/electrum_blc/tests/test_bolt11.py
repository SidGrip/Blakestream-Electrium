from hashlib import sha256
from decimal import Decimal
from binascii import unhexlify, hexlify
import pprint
import unittest

from electrum_blc.lnaddr import shorten_amount, unshorten_amount, LnAddr, lnencode, lndecode, u5_to_bitarray, bitarray_to_u5
from electrum_blc.segwit_addr import bech32_encode, bech32_decode
from electrum_blc import segwit_addr
from electrum_blc.lnutil import UnknownEvenFeatureBits, derive_payment_secret_from_payment_preimage, LnFeatures
from electrum_blc import constants

from . import ElectrumTestCase


RHASH=unhexlify('0001020304050607080900010203040506070809000102030405060708090102')
CONVERSION_RATE=1200
PRIVKEY=unhexlify('e126f68f7eafcc8b74f54d269fe206be715000f94dac067d1c04a8ca3b2db734')
PUBKEY=unhexlify('03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad')


class TestBolt11(ElectrumTestCase):
    def test_shorten_amount(self):
        tests = {
            Decimal(10)/10**12: '10p',
            Decimal(1000)/10**12: '1n',
            Decimal(1200)/10**12: '1200p',
            Decimal(123)/10**6: '123u',
            Decimal(123)/1000: '123m',
            Decimal(3): '3',
            Decimal(1000): '1000',
        }

        for i, o in tests.items():
            self.assertEqual(shorten_amount(i), o)
            assert unshorten_amount(shorten_amount(i)) == i

    @staticmethod
    def compare(a, b):

        if len([t[1] for t in a.tags if t[0] == 'h']) == 1:
            h1 = sha256([t[1] for t in a.tags if t[0] == 'h'][0].encode('utf-8')).digest()
            h2 = [t[1] for t in b.tags if t[0] == 'h'][0]
            assert h1 == h2

        # Need to filter out these, since they are being modified during
        # encoding, i.e., hashed
        a.tags = [t for t in a.tags if t[0] != 'h' and t[0] != 'n']
        b.tags = [t for t in b.tags if t[0] != 'h' and t[0] != 'n']

        assert b.pubkey.serialize() == PUBKEY, (hexlify(b.pubkey.serialize()), hexlify(PUBKEY))
        assert b.signature is not None

        # Unset these, they are generated during encoding/decoding
        b.pubkey = None
        b.signature = None

        assert a.__dict__ == b.__dict__, (pprint.pformat([a.__dict__, b.__dict__]))

    def test_roundtrip(self):
        longdescription = ('One piece of chocolate cake, one icecream cone, one'
                          ' pickle, one slice of swiss cheese, one slice of salami,'
                          ' one lollypop, one piece of cherry pie, one sausage, one'
                          ' cupcake, and one slice of watermelon')

        timestamp = 1615922274
        tests = [
            LnAddr(date=timestamp, paymenthash=RHASH, tags=[('d', '')]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=Decimal('0.001'), tags=[('d', '1 cup coffee'), ('x', 60)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=Decimal('1'), tags=[('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, net=constants.BitcoinTestnet, tags=[('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[
                ('r', [(unhexlify('029e03a901b85534ff1e92c43c74431f7ce72046060fcf7a95c37e148f78c77255'), unhexlify('0102030405060708'), 1, 20, 3),
                       (unhexlify('039e03a901b85534ff1e92c43c74431f7ce72046060fcf7a95c37e148f78c77255'), unhexlify('030405060708090a'), 2, 30, 4)]),
                ('f', 'BjAy6HHcvuCZENNE1yYsdicmJbHk6wxv9U'),
                ('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('f', '42E1A3zenTYursFanootRFtSKbHbxmNeTZ'), ('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('f', 'blc1qw508d6qejxtdg4y5r3zarvary0c5xw7k9yt5fn'), ('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('f', 'blc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q2vjpts'), ('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('n', PUBKEY), ('h', longdescription)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 514)]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 8))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 9))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 7) + (1 << 11))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 12))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 13))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 9) + (1 << 14))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 10 + (1 << 9) + (1 << 15))]),
            LnAddr(date=timestamp, paymenthash=RHASH, amount=24, tags=[('h', longdescription), ('9', 33282)], payment_secret=b"\x11" * 32),
        ]

        # Roundtrip
        for lnaddr1 in tests:
            invoice_str2 = lnencode(lnaddr1, PRIVKEY)
            expected_net = lnaddr1.net if lnaddr1.net else constants.BitcoinMainnet
            self.assertTrue(invoice_str2.startswith(f"ln{expected_net.BOLT11_HRP}"))
            lnaddr2 = lndecode(invoice_str2, net=lnaddr1.net)
            self.compare(lnaddr1, lnaddr2)

    def test_n_decoding(self):
        # We flip the signature recovery bit, which would normally give a different
        # pubkey.
        _, hrp, data = bech32_decode(
            lnencode(LnAddr(paymenthash=RHASH, amount=24, tags=[('d', '')]), PRIVKEY),
            ignore_long_length=True)
        databits = u5_to_bitarray(data)
        databits.invert(-1)
        lnaddr = lndecode(bech32_encode(segwit_addr.Encoding.BECH32, hrp, bitarray_to_u5(databits)), verbose=True)
        assert lnaddr.pubkey.serialize() != PUBKEY

        # But not if we supply expliciy `n` specifier!
        _, hrp, data = bech32_decode(
            lnencode(LnAddr(paymenthash=RHASH, amount=24, tags=[('d', ''), ('n', PUBKEY)]), PRIVKEY),
            ignore_long_length=True)
        databits = u5_to_bitarray(data)
        databits.invert(-1)
        lnaddr = lndecode(bech32_encode(segwit_addr.Encoding.BECH32, hrp, bitarray_to_u5(databits)), verbose=True)
        assert lnaddr.pubkey.serialize() == PUBKEY

    def test_min_final_cltv_expiry_decoding(self):
        lnaddr = lndecode(
            lnencode(
                LnAddr(
                    paymenthash=RHASH,
                    amount=Decimal('0.0005'),
                    net=constants.BitcoinSimnet,
                    tags=[('d', 'simnet-cltv'), ('c', 144)],
                ),
                PRIVKEY,
            ),
            net=constants.BitcoinSimnet,
        )
        self.assertEqual(144, lnaddr.get_min_final_cltv_expiry())

        lnaddr = lndecode(
            lnencode(
                LnAddr(
                    paymenthash=RHASH,
                    amount=Decimal('0.000015'),
                    net=constants.BitcoinTestnet,
                    tags=[('d', 'testnet-cltv'), ('c', 30)],
                ),
                PRIVKEY,
            ),
            net=constants.BitcoinTestnet,
        )
        self.assertEqual(30, lnaddr.get_min_final_cltv_expiry())

    def test_min_final_cltv_expiry_roundtrip(self):
        for cltv in (1, 15, 16, 31, 32, 33, 150, 511, 512, 513, 1023, 1024, 1025):
            lnaddr = LnAddr(paymenthash=RHASH, amount=Decimal('0.001'), tags=[('d', '1 cup coffee'), ('x', 60), ('c', cltv)])
            invoice = lnencode(lnaddr, PRIVKEY)
            self.assertEqual(cltv, lndecode(invoice).get_min_final_cltv_expiry())

    def test_features(self):
        lnaddr = lndecode(
            lnencode(
                LnAddr(
                    paymenthash=RHASH,
                    amount=Decimal('0.025'),
                    tags=[('d', 'features'), ('9', 514)],
                ),
                PRIVKEY,
            ),
        )
        self.assertEqual(514, lnaddr.get_tag('9'))
        self.assertEqual(LnFeatures(514), lnaddr.get_features())

        with self.assertRaises(UnknownEvenFeatureBits):
            lndecode(
                lnencode(
                    LnAddr(
                        paymenthash=RHASH,
                        amount=Decimal('0.025'),
                        tags=[('d', 'features-bad'), ('9', 514 + (1 << 100))],
                    ),
                    PRIVKEY,
                ),
            )

    def test_payment_secret(self):
        lnaddr = lndecode(
            lnencode(
                LnAddr(
                    paymenthash=RHASH,
                    amount=Decimal('0.025'),
                    tags=[('d', 'payment-secret'), ('9', (1 << 9) + (1 << 15) + (1 << 99))],
                    payment_secret=b"\x11" * 32,
                ),
                PRIVKEY,
            ),
        )
        self.assertEqual((1 << 9) + (1 << 15) + (1 << 99), lnaddr.get_tag('9'))
        self.assertEqual(b"\x11" * 32, lnaddr.payment_secret)

    def test_derive_payment_secret_from_payment_preimage(self):
        preimage = bytes.fromhex("cc3fc000bdeff545acee53ada12ff96060834be263f77d645abbebc3a8d53b92")
        self.assertEqual("bfd660b559b3f452c6bb05b8d2906f520c151c107b733863ed0cc53fc77021a8",
                         derive_payment_secret_from_payment_preimage(preimage).hex())
