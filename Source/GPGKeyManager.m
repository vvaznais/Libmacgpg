#import "Libmacgpg.h"
#import "GPGKeyManager.h"


@implementation GPGKeyManager
@synthesize allKeys=_allKeys;


- (void)loadAllKeys {
	[self loadKeys:nil sigs:NO uat:NO];
}

- (void)loadKeys:(NSSet *)keys sigs:(BOOL)sigs uat:(BOOL)uat {

	NSArray *keyArguments = [keys allObjects];
	
	
	// Get all fingerprints of the secret keys.
	GPGTask *gpgTask = [GPGTask gpgTask];
	gpgTask.batchMode = YES;
	[gpgTask addArgument:@"--list-secret-keys"];
	[gpgTask addArgument:@"--with-fingerprint"];
	[gpgTask addArguments:keyArguments];
	
	[gpgTask start];
	
	NSSet *secKeyFingerprints = [self fingerprintsFromColonListing:gpgTask.outText];
	
	
	
	// Get the infos from gpg.
	gpgTask = [GPGTask gpgTask];
	if (sigs) {
		[gpgTask addArgument:@"--list-sigs"];
		[gpgTask addArgument:@"--list-options"];
		[gpgTask addArgument:@"show-sig-subpackets=29"];
	} else {
		[gpgTask addArgument:@"--list-keys"];
	}
	if (uat) {
		_attributeLines = [NSMutableArray array];
		gpgTask.getAttributeData = YES;
	}
	[gpgTask addArgument:@"--with-fingerprint"];
	[gpgTask addArgument:@"--with-fingerprint"];
	[gpgTask addArguments:keyArguments];
	
	
	[gpgTask start];
	//TODO: Should we throw an error?
	/*if ([gpgTask start] != 0) {
		if ([keyList count] == 0) { //TODO: Bessere Lösung um Probleme zu vermeiden, wenn ein nicht (mehr) vorhandener Schlüssel gelistet werden soll.
			@throw [GPGException exceptionWithReason:localizedLibmacgpgString(@"List public keys failed!") gpgTask:gpgTask];
		}
	}*/
	
	
	
	
	
	// ======= Parsing =======
	
	NSMutableSet *newKeys = [[NSMutableSet alloc] init];
	NSMutableArray *userIDs = nil, *subkeys = nil, *signatures = nil;
	GPGKey *primaryKey = nil, *key = nil;
	GPGKeySignature *signature = nil;
	BOOL isPub = NO, isUid = NO, isRev = NO; // Used to differentiate pub/sub, uid/uat and sig/rev, because they are using the same if branch.
	NSMutableArray *allSignatures = nil;
	
	if (sigs) {
		allSignatures = [NSMutableArray array];
	}

	
	
	NSArray *lines = [gpgTask.outText componentsSeparatedByString:@"\n"];
	NSData *attributeData = gpgTask.attributeData; //attributeData is only needed for UATs (PhotoID).
	NSInteger attributeDataLoc = 0;
	
	for (NSString *line in lines) { //Loop thru all lines.
		NSArray *parts = [line componentsSeparatedByString:@":"];
		NSString *type = [parts objectAtIndex:0];
		
		if (([type isEqualToString:@"pub"] && (isPub = YES)) || [type isEqualToString:@"sub"]) { // Primary-key or subkey.
			key = [[[GPGKey alloc] init] autorelease];
			

			GPGValidity validity = [self validityForLetter:[parts objectAtIndex:1]];			
			
			key.length = [[parts objectAtIndex:2] intValue];
			
			key.algorithm = [[parts objectAtIndex:3] intValue];
			
			key.keyID = [parts objectAtIndex:4];

			key.creationDate = [NSDate dateWithGPGString:[parts objectAtIndex:5]];
			
			NSDate *expirationDate = [NSDate dateWithGPGString:[parts objectAtIndex:6]];
			key.expirationDate = expirationDate;
			if (!(validity & GPGValidityExpired) && expirationDate && [[NSDate date] isGreaterThanOrEqualTo:expirationDate]) {
				validity |= GPGValidityExpired;
			}
			
			key.ownerTrust = [self validityForLetter:[parts objectAtIndex:8]];

			const char *capabilities = [[parts objectAtIndex:11] UTF8String];
			for (; *capabilities; capabilities++) {
				switch (*capabilities) {
					case 'd':
					case 'D':
						validity |= GPGValidityDisabled;
						break;
					case 'e':
						key.canEncrypt = YES;
					case 'E':
						key.canAnyEncrypt = YES;
						break;
					case 's':
						key.canSign = YES;
					case 'S':
						key.canAnySign = YES;
						break;
					case 'c':
						key.canCertify = YES;
					case 'C':
						key.canAnyCertify = YES;
						break;
					case 'a':
						key.canAuthenticate = YES;
					case 'A':
						key.canAnyAuthenticate = YES;
						break;
				}
			}
			
			key.validity = validity;
			
			if (isPub) {
				isPub = NO;
				if (primaryKey) {
					[newKeys addObject:primaryKey]; //Add the last primaryKey
				}
				
				primaryKey = key;

				userIDs = [[NSMutableArray alloc] init];
				primaryKey.userIDs = userIDs;
				
				subkeys = [[NSMutableArray alloc] init];
				primaryKey.subkeys = subkeys;
			} else {
				[subkeys addObject:key];
			}
			key.primaryKey = primaryKey;
			
			
		}
		else if (([type isEqualToString:@"uid"] && (isUid = YES)) || [type isEqualToString:@"uat"]) { // UserID or UAT (PhotoID).
			GPGUserID *userID = [[[GPGUserID alloc] init] autorelease];
			userID.primaryKey = primaryKey;
			
			if (sigs) {
				signatures = [NSMutableArray array];
				userID.signatures = signatures;
			}
			
			
			GPGValidity validity = [self validityForLetter:[parts objectAtIndex:1]];

			key.creationDate = [NSDate dateWithGPGString:[parts objectAtIndex:5]];
			
			NSDate *expirationDate = [NSDate dateWithGPGString:[parts objectAtIndex:6]];
			key.expirationDate = expirationDate;
			if (!(validity & GPGValidityExpired) && expirationDate && [[NSDate date] isGreaterThanOrEqualTo:expirationDate]) {
				validity |= GPGValidityExpired;
			}

			userID.hashID = [parts objectAtIndex:7];
			
			
			if (parts.count > 11 && [[parts objectAtIndex:11] rangeOfString:@"D"].length > 0) {
				validity |= GPGValidityDisabled;
			}
			
			userID.validity = validity;
			
			
			if (isUid) {
				isUid = NO;
				userID.userID = [[parts objectAtIndex:9] unescapedString];
			} else if (uat) { // Process attribute data.
				NSInteger index, count;
				
				do {
					NSArray *attributeParts = [[_attributeLines objectAtIndex:0] componentsSeparatedByString:@" "];
					
					NSInteger length = [[attributeParts objectAtIndex:1] integerValue];
					index = [[attributeParts objectAtIndex:3] integerValue];
					count = [[attributeParts objectAtIndex:4] integerValue];
					
					switch ([[attributeParts objectAtIndex:2] integerValue]) {
						case 1: { // Image
							NSImage *image = [[NSImage alloc] initWithData:[attributeData subdataWithRange:NSMakeRange(attributeDataLoc + 16, length - 16)]];
							
							if (image) {
								NSImageRep *imageRep = [[image representations] objectAtIndex:0];
								NSSize size = imageRep.size;
								if (size.width != imageRep.pixelsWide || size.height != imageRep.pixelsHigh) { // Fix image size if needed.
									size.width = imageRep.pixelsWide;
									size.height = imageRep.pixelsHigh;
									imageRep.size = size;
									[image setSize:size];
								}
								
								userID.image = image;
								[image release];
							}					

							break;
						}
					}
					
					attributeDataLoc += length;
					
				} while (index < count);

			}
			[userIDs addObject:userID];
			
		}
		else if ([type isEqualToString:@"fpr"]) { // Fingerprint.
			NSString *fingerprint = [parts objectAtIndex:9];
			key.fingerprint = fingerprint;
			key.secret = [secKeyFingerprints containsObject:fingerprint];
			
		}
		else if ([type isEqualToString:@"sig"] || ([type isEqualToString:@"rev"] && (isRev = YES))) { // Signature.
			signature = [[[GPGKeySignature alloc] init] autorelease];
			
			
			signature.revocationSignature = isRev;
			
			signature.algorithm = [[parts objectAtIndex:3] intValue];
			
			signature.keyID = [parts objectAtIndex:4];
			
			signature.creationDate = [NSDate dateWithGPGString:[parts objectAtIndex:5]];
			
			signature.expirationDate = [NSDate dateWithGPGString:[parts objectAtIndex:6]];

			NSString *field = [parts objectAtIndex:10];
			signature.signatureClass = hexToByte([field UTF8String]);
			signature.local = [field hasSuffix:@"l"];
			
			
			[signatures addObject:signature];
			[allSignatures addObject:signature];
			
			isRev = NO;
		}
		else if ([type isEqualToString:@"spk"]) { // Signature subpacket. Needed for the revocation reason.
			switch ([[parts objectAtIndex:1] integerValue]) {
				case 29:
					signature.reason = [[parts objectAtIndex:4] unescapedString];
					break;
			}
		}
		
	}
	if (primaryKey) {
		[newKeys addObject:primaryKey]; //Add the last primaryKey
	}

	_attributeLines = nil;

	
	
	[_mutableAllKeys minusSet:keys];
	[_mutableAllKeys minusSet:newKeys];
	[_mutableAllKeys unionSet:newKeys];
	
	_once_keysByKeyID = 0;
	
	if (sigs) {
		NSDictionary *keysByKeyID = self.keysByKeyID;
		
		for (signature in allSignatures) {
			signature.primaryKey = [keysByKeyID objectForKey:signature.keyID]; // Set the key used to create the signature.
		}
	}
	
	
	
	
	NSSet *oldAllKeys = _allKeys;
	_allKeys = [_mutableAllKeys copy];
	[oldAllKeys release];
}



- (NSDictionary *)keysByKeyID {
	dispatch_once(&_once_keysByKeyID, ^{
		
		NSMutableDictionary *keysByKeyID = [[NSMutableDictionary alloc] init];
		for (GPGKey *key in _mutableAllKeys) {
			[keysByKeyID setObject:key forKey:key.keyID];
			for (GPGKey *subkey in key.subkeys) {
				[keysByKeyID setObject:subkey forKey:subkey.keyID];
			}
		}
		
		NSDictionary *old = _keysByKeyID;
		_keysByKeyID = keysByKeyID;
		[old release];
	});
	
	return [[_keysByKeyID retain] autorelease];
}



#pragma mark Helper methods

- (GPGValidity)validityForLetter:(NSString *)letter {
	if ([letter length] == 0) {
		return GPGValidityUnknown;
	}
	switch ([letter characterAtIndex:0]) {
		case 'q':
			return GPGValidityUndefined;
		case 'n':
			return GPGValidityNever;
		case 'm':
			return GPGValidityMarginal;
		case 'f':
			return GPGValidityFull;
		case 'u':
			return GPGValidityUltimate;
		case 'i':
			return GPGValidityInvalid;
		case 'r':
			return GPGValidityRevoked;
		case 'e':
			return GPGValidityExpired;
		case 'd':
			return GPGValidityDisabled;
	}
	return GPGValidityUnknown;
}

- (NSSet *)fingerprintsFromColonListing:(NSString *)colonListing {
	NSRange searchRange, findRange;
	NSUInteger textLength = [colonListing length];
	NSMutableSet *fingerprints = [NSMutableSet setWithCapacity:3];
	NSString *lineText;
	
	searchRange.location = 0;
	searchRange.length = textLength;
	
	
	while ((findRange = [colonListing rangeOfString:@"\nfpr:" options:NSLiteralSearch range:searchRange]).length > 0) {
		findRange.location++;
		lineText = [colonListing substringWithRange:[colonListing lineRangeForRange:findRange]];
		[fingerprints addObject:[[lineText componentsSeparatedByString:@":"] objectAtIndex:9]];
		
		searchRange.location = findRange.location + findRange.length;
		searchRange.length = textLength - searchRange.location;
	}
	
	return fingerprints;
}



#pragma mark Delegate

- (id)gpgTask:(GPGTask *)gpgTask statusCode:(NSInteger)status prompt:(NSString *)prompt {
	switch (status) {
		case GPG_STATUS_ATTRIBUTE:
			[_attributeLines addObject:prompt];
			break;
			
	}
	return nil;
}



#pragma mark Singleton

+ (GPGKeyManager *)sharedInstance {
	static dispatch_once_t onceToken;
    static GPGKeyManager *sharedInstance;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[super allocWithZone:nil] realInit];
    });
    
    return sharedInstance;
}

- (id)realInit {
	if (!(self = [super init])) {
		return nil;
	}
	
	_mutableAllKeys = [[NSMutableSet alloc] init];
	
	return self;
}

+ (id)allocWithZone:(NSZone *)zone {
    return [[self sharedInstance] retain];
}

- (id)init {
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id)retain {
    return self;
}

- (NSUInteger)retainCount {
    return NSUIntegerMax;
}

- (oneway void)release {
}

- (id)autorelease {
    return self;
}



@end
