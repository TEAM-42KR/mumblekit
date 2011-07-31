/* Copyright (C) 2009-2010 Mikkel Krautz <mikkel@krautz.dk>
   Copyright (c) 2005-2010 Thorvald Natvig, <thorvald@natvig.com>

   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
   - Neither the name of the Mumble Developers nor the names of its
     contributors may be used to endorse or promote products derived from this
     software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import <MumbleKit/MKCertificate.h>

#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pkcs12.h>

#import <CommonCrypto/CommonDigest.h>


NSString *MKCertificateItemCommonName   = @"CN";
NSString *MKCertificateItemCountry      = @"C";
NSString *MKCertificateItemOrganization = @"O";
NSString *MKCertificateItemSerialNumber = @"serialNumber";


static int add_ext(X509 * crt, int nid, char *value) {
	X509_EXTENSION *ex;
	X509V3_CTX ctx;
	X509V3_set_ctx_nodb(&ctx);
	X509V3_set_ctx(&ctx, crt, crt, NULL, NULL, 0);
	ex = X509V3_EXT_conf_nid(NULL, &ctx, nid, value);
	if (!ex)
		return 0;
	
	X509_add_ext(crt, ex, -1);
	X509_EXTENSION_free(ex);
	return 1;
}

@interface MKCertificate () {
    NSData          *_derCert;
	NSData          *_derPrivKey;
    
	NSDictionary    *_subjectDict;
	NSDictionary    *_issuerDict;
    
	NSDate          *_notAfterDate;
	NSDate          *_notBeforeDate;
    
	NSMutableArray  *_emailAddresses;
	NSMutableArray  *_dnsEntries;
}

- (void) setCertificate:(NSData *)cert;
- (NSData *) certificate;

- (void) setPrivateKey:(NSData *)pkey;
- (NSData *) privateKey;

- (void) extractCertInfo;

@end

@implementation MKCertificate

// fixme(mkrautz): Move this function somewhere else if other pieces of the library
//                 needs OpenSSL.
+ (void) initialize {
	// Make sure OpenSSL is initialized...
	OpenSSL_add_all_algorithms();

	// On Unix systems OpenSSL makes sure its PRNG is seeded with
	// random data from /dev/random or /dev/urandom. It would probably
	// be a good idea to seed it more than this. Fixme?
}

- (void) dealloc {
	[_derCert release];
	[_derPrivKey release];
	[super dealloc];
}

- (void) setCertificate:(NSData *)cert {
	_derCert = [cert retain];
}

- (NSData *) certificate {
	return _derCert;
}

- (void) setPrivateKey:(NSData *)pkey {
	_derPrivKey = [pkey retain];
}

- (NSData *) privateKey {
	return _derPrivKey;
}

// Returns an autoreleased MKCertificate object constructed by the given DER-encoded
// certificate and private key.
+ (MKCertificate *) certificateWithCertificate:(NSData *)cert privateKey:(NSData *)privkey {
	MKCertificate *ourCert = [[MKCertificate alloc] init];
	[ourCert setCertificate:cert];
	[ourCert setPrivateKey:privkey];
	[ourCert extractCertInfo];
	return [ourCert autorelease];
}

// Generate a self-signed certificate with the given name and email address as
// a MKCertificate object.
+ (MKCertificate *) selfSignedCertificateWithName:(NSString *)aName email:(NSString *)anEmail {
	CRYPTO_mem_ctrl(CRYPTO_MEM_CHECK_ON);

	X509 *x509 = X509_new();
	EVP_PKEY *pkey = EVP_PKEY_new();
	RSA *rsa = RSA_generate_key(2048, RSA_F4, NULL, NULL);
	EVP_PKEY_assign_RSA(pkey, rsa);

	X509_set_version(x509, 2);
	ASN1_INTEGER_set(X509_get_serialNumber(x509),1);
	X509_gmtime_adj(X509_get_notBefore(x509),0);
	X509_gmtime_adj(X509_get_notAfter(x509),60*60*24*365*20);
	X509_set_pubkey(x509, pkey);

	X509_NAME *name = X509_get_subject_name(x509);

	NSString *certName = aName;
	if (certName == nil) {
		certName = @"Mumble User";
	}

	NSString *certEmail = nil;
	if (anEmail == nil)
		anEmail = @"";
	certEmail = [NSString stringWithFormat:@"email:%@", anEmail];

	X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (unsigned char *)[certName UTF8String], -1, -1, 0);
	X509_set_issuer_name(x509, name);
	add_ext(x509, NID_basic_constraints, "critical,CA:FALSE");
	add_ext(x509, NID_ext_key_usage, "clientAuth");
	add_ext(x509, NID_subject_key_identifier, "hash");
	add_ext(x509, NID_netscape_comment, "Generated by Mumble");
	add_ext(x509, NID_subject_alt_name, (char *)[certEmail UTF8String]);

	X509_sign(x509, pkey, EVP_sha1());

	MKCertificate *cert = [[MKCertificate alloc] init];
	{
		NSMutableData *data = [[NSMutableData alloc] initWithLength:i2d_X509(x509, NULL)];
		unsigned char *ptr = [data mutableBytes];
		i2d_X509(x509, &ptr);
		[cert setCertificate:data];
		[data release];
	}
	{
		NSMutableData *data = [[NSMutableData alloc] initWithLength:i2d_PrivateKey(pkey, NULL)];
		unsigned char *ptr = [data mutableBytes];
		i2d_PrivateKey(pkey, &ptr);
		[cert setPrivateKey:data];
		[data release];
	}
	
	X509_free(x509);

	return [cert autorelease];
}

// Import a PKCS12-encoded certificate, public key and private key using the given password.
+ (MKCertificate *) certificateWithPKCS12:(NSData *)pkcs12 password:(NSString *)password {
    MKCertificate *retcert = nil;
    X509 *x509 = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *pkcs = NULL;
    BIO *mem = NULL;
    STACK_OF(X509) *certs = NULL;
    int ret;

    mem = BIO_new_mem_buf((void *)[pkcs12 bytes], [pkcs12 length]);
    (void) BIO_set_close(mem, BIO_NOCLOSE);
    pkcs = d2i_PKCS12_bio(mem, NULL);
    if (pkcs) {
        ret = PKCS12_parse(pkcs, NULL, &pkey, &x509, &certs);
        if (pkcs && !pkey && !x509 && [password length] > 0) {
            if (certs) {
                if (ret)
                    sk_X509_free(certs);
                certs = NULL;
            }
            ret = PKCS12_parse(pkcs, [password UTF8String], &pkey, &x509, &certs);
        }
        if (pkey && x509 && X509_check_private_key(x509, pkey)) {
            unsigned char *dptr;

            NSMutableData *key = [NSMutableData dataWithLength:i2d_PrivateKey(pkey, NULL)];
            dptr = [key mutableBytes];
            i2d_PrivateKey(pkey, &dptr);

            NSMutableData *crt = [NSMutableData dataWithLength:i2d_X509(x509, NULL)];
            dptr = [crt mutableBytes];
            i2d_X509(x509, &dptr);

            retcert = [MKCertificate certificateWithCertificate:crt privateKey:key];
		}
	}

	if (ret) {
        if (pkey)
            EVP_PKEY_free(pkey);
        if (x509)
            X509_free(x509);
        if (certs)
            sk_X509_free(certs);
    }
    if (pkcs)
        PKCS12_free(pkcs);
    if (mem)
        BIO_free(mem);

	return retcert;
}

// Export a MKCertificate object as a PKCS12-encoded NSData blob. This is useful for
// APIs that only accept PKCS12 encoded data for import, like some the iOS keychain
// APIs.
- (NSData *) exportPKCS12WithPassword:(NSString *)password {
	X509 *x509 = NULL;
	EVP_PKEY *pkey = NULL;
	PKCS12 *pkcs = NULL;
	BIO *mem = NULL;
	STACK_OF(X509) *certs = sk_X509_new_null();
	const unsigned char *p;
	long size;
	char *data = NULL;
	NSData *retData = nil;

	if (!_derCert || !_derPrivKey) {
		return nil;
	}

	p = [_derPrivKey bytes];
	pkey = d2i_AutoPrivateKey(NULL, &p, [_derPrivKey length]);

	if (pkey) {
		p = [_derCert bytes];
		x509 = d2i_X509(NULL, &p, [_derCert length]);

		if (x509 && X509_check_private_key(x509, pkey)) {
			X509_keyid_set1(x509, NULL, 0);
			X509_alias_set1(x509, NULL, 0);

			/* fixme(mkrautz): Currently we only support exporting our own self-signed certs,
			   which obviously do not have any intermediate certificates. If we need to add
			   this in the future, do this: */
#if 0
			for (/* each certificate*/) {
				unsigned char *p = [data bytes];
				X509 *c = d2i_X509(NULL, &p, [data len])
				if (c)
					sk_X509_push(certs, c);
			}
#endif

			pkcs = PKCS12_create(password ? [password UTF8String] : NULL, "Mumble Identity", pkey, x509, certs, 0, 0, 0, 0, 0);
			if (pkcs) {
				mem = BIO_new(BIO_s_mem());
				i2d_PKCS12_bio(mem, pkcs);
				BIO_flush(mem);
				size = BIO_get_mem_data(mem, &data);
				retData = [[NSData alloc] initWithBytes:data length:size];
			}
		}
	}

	if (pkey)
		EVP_PKEY_free(pkey);
	if (x509)
		X509_free(x509);
	if (pkcs)
		PKCS12_free(pkcs);
	if (mem)
		BIO_free(mem);
	if (certs)
		sk_X509_free(certs);

	return [retData autorelease];
}

- (BOOL) hasCertificate {
	return _derCert != nil;
}

- (BOOL) hasPrivateKey {
	return _derPrivKey != nil;
}

// Parse a one-line ASCII representation of subject or issuer info
// from a certificate. Returns a dictionary with the keys and values
// as-is.
- (NSDictionary *) dictForOneLineASCIIRepr:(char *)asciiRepr {
	char *cur = asciiRepr;
	NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
	char *key = NULL, *val = NULL;
	while (1) {
		if (*cur == '/') {
			*cur = '\0';
			if (key) {
				[dict setValue:[NSString stringWithCString:val encoding:NSASCIIStringEncoding]
						forKey:[NSString stringWithCString:key encoding:NSASCIIStringEncoding]];
			}
			key = cur+1;
		} else if (*cur == '=') {
			*cur = '\0';
			val = cur+1;
		} else if (*cur == '\0') {
			[dict setValue:[NSString stringWithCString:val encoding:NSASCIIStringEncoding]
					forKey:[NSString stringWithCString:key encoding:NSASCIIStringEncoding]];
			break;
		}
		++cur;
	}
	return (NSDictionary *)dict;
}

// Parse an ASN1 string representing time.
// GeneralizedTime: http://www.obj-sys.com/asn1tutorial/node14.html
// UTCTime: http://www.obj-sys.com/asn1tutorial/node15.html
// Also, a gem from http://www.columbia.edu/~ariel/ssleay/asn1-time.html:
// "UTCTIME is used to encode values with year 1950 through 2049."
//
// fixme(mkrautz): This needs some testing. And fuzzing.
//                 Also, are "local time only" times supposed to be handled?
- (NSDate *) parseASN1Date:(ASN1_TIME *)time {
	int Y = 0, M = 0, D = 0, h = 0, m = 0, s = 0, sfrac = 0, th = 0, tm = 0, sign = 0;
	unsigned char *p = time->data;

	if (time->type == V_ASN1_UTCTIME && time->length-1 >= 10) {
		Y = (p[0]-'0')*10 + (p[1]-'0');
		if (Y > 49)
			Y += 1900;
		else
			Y += 2000;
		M = (p[2]-'0')*10 + (p[3]-'0');
		D = (p[4]-'0')*10 + (p[5]-'0');
		h = (p[6]-'0')*10 + (p[7]-'0');
		m = (p[7]-'0')*10 + (p[8]-'0');
		if (p[9] == 'Z' || p[9] == '+' || p[9] == '-') {
			if (time->length-1 >= 13 && p[9] != 'Z') {
				sign = p[9] == '+' ? 1 : -1;
				th = ((p[10]-'0')*10 + (p[11]-'0'));
				tm = ((p[12]-'0')*10 + (p[13]-'0'));
			}
		} else {
			s = (p[9]-'0')*10 + (p[10]-'0');
		}
		if (time->length-1 >= 11 && (p[11] == 'Z' || p[11] == '+' || p[11] == '-')) {
			if (time->length-1 >= 15 && p[11] != 'Z') {
				sign = p[11] == '+' ? 1 : -1;
				th = ((p[12]-'0')*10 + (p[13]-'0'));
				tm = ((p[14]-'0')*10 + (p[15]-'0'));
			}
		} else if (time->length-1 >= 15 && p[11] == '.') {
			sfrac = (p[12]-'0')*100 + (p[13]-'0')*10 + (p[14]-'0');
			if (p[15] == 'Z' || p[15] == '+' || p[15] == '-') {
				if (time->length-1 >= 17 && p[15] != 'Z') {
					sign = p[15] == '+' ? 1 : -1;
					th = ((p[16]-'0')*10 + (p[17]-'0'));
					tm = ((p[16]-'0')*10 + (p[17]-'0'));
				}
			}
		}
	} else if (time->type == V_ASN1_GENERALIZEDTIME && time->length-1 >= 14) {
		Y = (p[0]-'0')*1000 + (p[1]-'0')*100 + (p[2]-'0')*10 + (p[3]-'0');
		M = (p[4]-'0')*10 + (p[5]-'0');
		D = (p[6]-'0')*10 + (p[7]-'0');
		h = (p[8]-'0')*10 + (p[9]-'0');
		m = (p[10]-'0')*10 + (p[11]-'0');
		s = (p[12]-'0')*10 + (p[13]-'0');
		if (time->length-1 >= 18 && p[14] == '.') {
			sfrac = (p[15]-'0')*100 + (p[16]-'0')*10 + (p[17]-'0');
			if (p[18] == 'Z' || p[18] == '+' || p[18] == '-') {
				if (time->length-1 >= 22 && p[18] != 'Z') {
					sign = p[18] == '+' ? 1 : -1;
					th = ((p[19]-'0')*10 + (p[20]-'0'));
					tm = ((p[21]-'0')*10 + (p[22]-'0'));
				}
			}
		} else if (p[14] == 'Z' || p[14] == '+' || p[14] == '-') {
			if (time->length-1 >= 18 && p[14] != 'Z') {
				sign = p[14] == '+' ? 1 : -1;
				th = ((p[15]-'0')*10 + (p[16]-'0'));
				tm = ((p[17]-'0')*10 + (p[18]-'0'));
			}
		}
	}

	return [[NSDate alloc] initWithString:
			[NSString stringWithFormat:@"%.4i-%.2i-%.2i %.2i-%.2i-%.2i %c%.2i%.2i",
					Y, M, D, h, m, s, sign > 0 ? '+' : '-', th, tm]];
}

- (void) extractCertInfo {
	X509 *x509 = NULL;
	const unsigned char *p = NULL;

	p = [_derCert bytes];
	x509 = d2i_X509(NULL, &p, [_derCert length]);

	if (x509) {
		// Extract subject information
		{
			X509_NAME *subject = X509_get_subject_name(x509);
			char *asciiRepr = X509_NAME_oneline(subject, NULL, 0);
			if (asciiRepr) {
				_subjectDict = [self dictForOneLineASCIIRepr:asciiRepr];
				OPENSSL_free(asciiRepr);
			}
		}

		// Extract issuer information
		{
			X509_NAME *issuer = X509_get_issuer_name(x509);
			char *asciiRepr = X509_NAME_oneline(issuer, NULL, 0);
			if (asciiRepr) {
				_issuerDict = [self dictForOneLineASCIIRepr:asciiRepr];
				OPENSSL_free(asciiRepr);
			}
		}

		// Extract notBefore and notAfter
		ASN1_TIME *notBefore = X509_get_notBefore(x509);
		if (notBefore) {
			_notBeforeDate = [self parseASN1Date:notBefore];
		}
		ASN1_TIME *notAfter = X509_get_notAfter(x509);
		if (notAfter) {
			_notAfterDate = [self parseASN1Date:notAfter];
		}

		// Extract Subject Alt Names
		STACK_OF(GENERAL_NAME) *subjAltNames = X509_get_ext_d2i(x509, NID_subject_alt_name, NULL, NULL);
		int num = sk_GENERAL_NAME_num(subjAltNames);
		for (int i = 0; i < num; i++) {
			GENERAL_NAME *name = sk_GENERAL_NAME_value(subjAltNames, i);
			unsigned char *strPtr = NULL;

			switch (name->type) {
				case GEN_DNS: {
					if (!_dnsEntries)
						_dnsEntries = [[NSMutableArray alloc] init];
					ASN1_STRING_to_UTF8(&strPtr, name->d.ia5);
					NSString *dns = [[NSString alloc] initWithUTF8String:(char *)strPtr];
					[_dnsEntries addObject:dns];
					break;
				}
				case GEN_EMAIL: {
					if (!_emailAddresses)
						_emailAddresses = [[NSMutableArray alloc] init];
					ASN1_STRING_to_UTF8(&strPtr, name->d.ia5);
					NSString *email = [[NSString alloc] initWithUTF8String:(char *)strPtr];
					[_emailAddresses addObject:email];
					break;
				}
				// fixme(mkrautz): There's an URI alt name as well.
				default:
					break;
			}

			OPENSSL_free(strPtr);
		}

		sk_pop_free(subjAltNames, sk_free);
		X509_free(x509);
	}
}

// Return a SHA1 digest of the contents of the certificate
- (NSData *) digest {
	if (_derCert == nil)
		return nil;

	unsigned char buf[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1([_derCert bytes], [_derCert length], buf);
	return [NSData dataWithBytes:buf length:CC_SHA1_DIGEST_LENGTH];
}

// Return a hex-encoded SHA1 digest of the contents of the certificate
- (NSString *) hexDigest {
	if (_derCert == nil)
		return nil;

	const char *tbl = "0123456789abcdef";
	char hexstr[CC_SHA1_DIGEST_LENGTH*2 + 1];
	unsigned char *buf = (unsigned char *)[[self digest] bytes];
	for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
		hexstr[2*i+0] = tbl[(buf[i] >> 4) & 0x0f];
		hexstr[2*i+1] = tbl[buf[i] & 0x0f];
	}
	hexstr[CC_SHA1_DIGEST_LENGTH*2] = 0;
	return [NSString stringWithCString:hexstr encoding:NSASCIIStringEncoding];
}

// Get the common name of a MKCertificate.  If no common name is available,
// nil is returned.
- (NSString *) commonName {
	return [_subjectDict objectForKey:MKCertificateItemCommonName];
}

// Get the email of the subject of the MKCertificate.  If no email is available,
// nil is returned.
- (NSString *) emailAddress {
	if (_emailAddresses && [_emailAddresses count] > 0) {
		return [_emailAddresses objectAtIndex:0];
	}
	return nil;
}

// Get the issuer name of the MKCertificate.  If no issuer is present, nil is returned.
- (NSString *) issuerName {
	return [self issuerItem:MKCertificateItemCommonName];
}

// Returns the expiry date of the certificate.
- (NSDate *) notAfter {
	return _notAfterDate;
}

// Returns the notBefore date of the certificate.
- (NSDate *) notBefore {
	return _notBeforeDate;
}

// Look up an issuer item.
- (NSString *) issuerItem:(NSString *)item {
	return [_issuerDict objectForKey:item];
}

// Look up a subject item.
- (NSString *) subjectItem:(NSString *)item {
	return [_subjectDict objectForKey:item];
}

@end
