/*
 * Tencent is pleased to support the open source community by making
 * MMKV available.
 *
 * Copyright (C) 2018 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the BSD 3-Clause License (the "License"); you may not use
 * this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 *       https://opensource.org/licenses/BSD-3-Clause
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "MMKV.h"
#import <Core/MMKV.h>
#import <Core/ScopedLock.hpp>
#import <Core/aes/openssl/md5.h>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#endif

#define MMKVDebug NSLog
#define MMKVInfo NSLog
#define MMKVWarning NSLog
#define MMKVError NSLog

using namespace std;

static NSMutableDictionary *g_instanceDic;
static mmkv::ThreadLock g_lock;
id<MMKVHandler> g_callbackHandler;
bool g_isLogRedirecting = false;

#define SPECIAL_CHARACTER_DIRECTORY_NAME @"specialCharacter"

static NSString *md5(NSString *value);
static NSString *encodeMmapID(NSString *mmapID);

enum : bool {
    KeepSequence = false,
    IncreaseSequence = true,
};

@implementation MMKV {
    NSString *m_mmapID;
    mmkv::MMKV *m_mmkv;
}

#pragma mark - init

+ (void)initialize {
    if (self == MMKV.class) {
        g_instanceDic = [NSMutableDictionary dictionary];
        g_lock = mmkv::ThreadLock();
        g_lock.initialize();

        mmkv::MMKV::initializeMMKV([self mmkvBasePath].UTF8String, mmkv::MMKVLogInfo);

        MMKVInfo(@"pagesize:%zu", mmkv::DEFAULT_MMAP_SIZE);

#ifdef MMKV_IOS
        auto appState = [UIApplication sharedApplication].applicationState;
        auto isInBackground = (appState == UIApplicationStateBackground);
        mmkv::MMKV::setIsInBackground(isInBackground);
        MMKVInfo(@"appState:%ld", (long) appState);

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
#endif
    }
}

// a generic purpose instance
+ (instancetype)defaultMMKV {
    return [MMKV mmkvWithID:@"" DEFAULT_MMAP_ID];
}

// any unique ID (com.tencent.xin.pay, etc)
+ (instancetype)mmkvWithID:(NSString *)mmapID {
    return [MMKV mmkvWithID:mmapID cryptKey:nil];
}

+ (instancetype)mmkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey {
    return [MMKV mmkvWithID:mmapID cryptKey:cryptKey relativePath:nil];
}

+ (instancetype)mmkvWithID:(NSString *)mmapID relativePath:(nullable NSString *)path {
    return [MMKV mmkvWithID:mmapID cryptKey:nil relativePath:path];
}

+ (instancetype)mmkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey relativePath:(nullable NSString *)relativePath {
    if (mmapID.length <= 0) {
        return nil;
    }

    // TODO: calc kvKey from mmkv::MMKV::xxx()
    NSString *kvPath = [MMKV mappedKVPathWithID:mmapID relativePath:relativePath];
    if (!mmkv::isFileExist(kvPath.UTF8String)) {
        if (!mmkv::createFile(kvPath.UTF8String)) {
            MMKVError(@"fail to create file at %@", kvPath);
            return nil;
        }
    }
    NSString *kvKey = [MMKV mmapKeyWithMMapID:mmapID relativePath:relativePath];

    SCOPEDLOCK(g_lock);

    MMKV *kv = [g_instanceDic objectForKey:kvKey];
    if (kv == nil) {
        kv = [[MMKV alloc] initWithMMapID:mmapID cryptKey:cryptKey path:relativePath];
        [g_instanceDic setObject:kv forKey:kvKey];
    }
    return kv;
}

- (instancetype)initWithMMapID:(NSString *)kvKey cryptKey:(NSData *)cryptKey path:(NSString *)path {
    if (self = [super init]) {
        string pathTmp;
        if (path.length > 0) {
            pathTmp = path.UTF8String;
        }
        string cryptKeyTmp;
        if (cryptKey.length > 0) {
            cryptKeyTmp = string((char *) cryptKey.bytes, cryptKey.length);
        }
        string *pathPtr = pathTmp.empty() ? nullptr : &pathTmp;
        string *cryptKeyPtr = cryptKeyTmp.empty() ? nullptr : &cryptKeyTmp;
        m_mmkv = mmkv::MMKV::mmkvWithID(kvKey.UTF8String, mmkv::MMKV_SINGLE_PROCESS, cryptKeyPtr, pathPtr);
        m_mmapID = [NSString stringWithUTF8String:m_mmkv->mmapID().c_str()];

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
#endif
    }
    return self;
}

- (void)dealloc {
    [self clearMemoryCache];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Application state

#ifdef MMKV_IOS
- (void)onMemoryWarning {
    MMKVInfo(@"cleaning on memory warning %@", m_mmapID);

    [self clearMemoryCache];
}

+ (void)didEnterBackground {
    mmkv::MMKV::setIsInBackground(true);
    MMKVInfo(@"isInBackground:%d", true);
}

+ (void)didBecomeActive {
    mmkv::MMKV::setIsInBackground(false);
    MMKVInfo(@"isInBackground:%d", false);
}
#endif

- (void)clearAll {
    m_mmkv->clearAll();
}

- (void)clearMemoryCache {
    if (m_mmkv) {
        m_mmkv->clearMemoryCache();
    }
}

- (void)close {
    SCOPEDLOCK(g_lock);
    MMKVInfo(@"closing %@", m_mmapID);

    m_mmkv->close();
    m_mmkv = nullptr;

    [g_instanceDic removeObjectForKey:m_mmapID];
}

- (void)trim {
    m_mmkv->trim();
}

#pragma mark - encryption & decryption

- (nullable NSData *)cryptKey {
    auto str = m_mmkv->cryptKey();
    return [NSData dataWithBytes:str.data() length:str.length()];
}

- (BOOL)reKey:(NSData *)newKey {
    string key;
    if (newKey.length > 0) {
        key = string((char *) newKey.bytes, newKey.length);
    }
    return m_mmkv->reKey(key);
}

#pragma mark - set & get

- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key {
    return m_mmkv->set(object, key);
}

- (BOOL)setBool:(BOOL)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setFloat:(float)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setDouble:(double)value forKey:(NSString *)key {
    return m_mmkv->set(value, key);
}

- (BOOL)setString:(NSString *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (BOOL)setData:(NSData *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (id)getObjectOfClass:(Class)cls forKey:(NSString *)key {
    return m_mmkv->getObject(key, cls);
}

- (BOOL)getBoolForKey:(NSString *)key {
    return [self getBoolForKey:key defaultValue:FALSE];
}
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    return m_mmkv->getBool(key, defaultValue);
}

- (int32_t)getInt32ForKey:(NSString *)key {
    return [self getInt32ForKey:key defaultValue:0];
}
- (int32_t)getInt32ForKey:(NSString *)key defaultValue:(int32_t)defaultValue {
    return m_mmkv->getInt32(key, defaultValue);
}

- (uint32_t)getUInt32ForKey:(NSString *)key {
    return [self getUInt32ForKey:key defaultValue:0];
}
- (uint32_t)getUInt32ForKey:(NSString *)key defaultValue:(uint32_t)defaultValue {
    return m_mmkv->getUInt32(key, defaultValue);
}

- (int64_t)getInt64ForKey:(NSString *)key {
    return [self getInt64ForKey:key defaultValue:0];
}
- (int64_t)getInt64ForKey:(NSString *)key defaultValue:(int64_t)defaultValue {
    return m_mmkv->getInt64(key, defaultValue);
}

- (uint64_t)getUInt64ForKey:(NSString *)key {
    return [self getUInt64ForKey:key defaultValue:0];
}
- (uint64_t)getUInt64ForKey:(NSString *)key defaultValue:(uint64_t)defaultValue {
    return m_mmkv->getUInt64(key, defaultValue);
}

- (float)getFloatForKey:(NSString *)key {
    return [self getFloatForKey:key defaultValue:0];
}
- (float)getFloatForKey:(NSString *)key defaultValue:(float)defaultValue {
    return m_mmkv->getFloat(key, defaultValue);
}

- (double)getDoubleForKey:(NSString *)key {
    return [self getDoubleForKey:key defaultValue:0];
}
- (double)getDoubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    return m_mmkv->getDouble(key, defaultValue);
}

- (nullable NSString *)getStringForKey:(NSString *)key {
    return [self getStringForKey:key defaultValue:nil];
}
- (nullable NSString *)getStringForKey:(NSString *)key defaultValue:(nullable NSString *)defaultValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSString *valueString = [self getObjectOfClass:NSString.class forKey:key];
    if (!valueString) {
        valueString = defaultValue;
    }
    return valueString;
}

- (nullable NSDate *)getDateForKey:(NSString *)key {
    return [self getDateForKey:key defaultValue:nil];
}
- (nullable NSDate *)getDateForKey:(NSString *)key defaultValue:(nullable NSDate *)defaultValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSDate *valueDate = [self getObjectOfClass:NSDate.class forKey:key];
    if (!valueDate) {
        valueDate = defaultValue;
    }
    return valueDate;
}

- (nullable NSData *)getDataForKey:(NSString *)key {
    return [self getDataForKey:key defaultValue:nil];
}
- (nullable NSData *)getDataForKey:(NSString *)key defaultValue:(nullable NSData *)defaultValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSData *valueData = [self getObjectOfClass:NSData.class forKey:key];
    if (!valueData) {
        valueData = defaultValue;
    }
    return valueData;
}

- (size_t)getValueSizeForKey:(NSString *)key NS_SWIFT_NAME(valueSize(forKey:)) {
    return m_mmkv->getValueSize(key, false);
}

#pragma mark - enumerate

- (BOOL)containsKey:(NSString *)key {
    return m_mmkv->containsKey(key);
}

- (size_t)count {
    return m_mmkv->count();
}

- (size_t)totalSize {
    return m_mmkv->totalSize();
}

- (size_t)actualSize {
    return m_mmkv->actualSize();
}

- (void)enumerateKeys:(void (^)(NSString *key, BOOL *stop))block {
    m_mmkv->enumerateKeys(block);
}

- (NSArray *)allKeys {
    return m_mmkv->allKeys();
}

- (void)removeValueForKey:(NSString *)key {
    m_mmkv->removeValueForKey(key);
}

- (void)removeValuesForKeys:(NSArray *)arrKeys {
    m_mmkv->removeValuesForKeys(arrKeys);
}

#pragma mark - Boring stuff

- (void)sync {
    m_mmkv->sync(MMKV_SYNC);
}

- (void)async {
    m_mmkv->sync(MMKV_ASYNC);
}

static NSString *g_basePath = nil;
+ (NSString *)mmkvBasePath {
    if (g_basePath.length > 0) {
        return g_basePath;
    }

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentPath = (NSString *) [paths firstObject];
    if ([documentPath length] > 0) {
        g_basePath = [documentPath stringByAppendingPathComponent:@"mmkv"];
        return g_basePath;
    } else {
        return @"";
    }
}

+ (void)setMMKVBasePath:(NSString *)basePath {
    if (basePath.length > 0) {
        g_basePath = basePath;
        MMKVInfo(@"set MMKV base path to: %@", g_basePath);
    }
}

+ (NSString *)mmapKeyWithMMapID:(NSString *)mmapID relativePath:(nullable NSString *)relativePath {
    NSString *string = nil;
    if ([relativePath length] > 0 && [relativePath isEqualToString:[MMKV mmkvBasePath]] == NO) {
        string = md5([relativePath stringByAppendingPathComponent:mmapID]);
    } else {
        string = mmapID;
    }
    MMKVInfo(@"mmapKey: %@", string);
    return string;
}

+ (NSString *)mappedKVPathWithID:(NSString *)mmapID relativePath:(nullable NSString *)path {
    NSString *basePath = nil;
    if ([path length] > 0) {
        basePath = path;
    } else {
        basePath = [self mmkvBasePath];
    }

    if ([basePath length] > 0) {
        NSString *mmapIDstring = encodeMmapID(mmapID);
        return [basePath stringByAppendingPathComponent:mmapIDstring];
    } else {
        return @"";
    }
}

+ (NSString *)crcPathWithMappedKVPath:(NSString *)kvPath {
    return [kvPath stringByAppendingString:@".crc"];
}

+ (BOOL)isFileValid:(NSString *)mmapID {
    return [self isFileValid:mmapID relativePath:nil];
}

+ (BOOL)isFileValid:(NSString *)mmapID relativePath:(nullable NSString *)path {
    if (mmapID.length > 0) {
        if (path.length > 0) {
            // TODO: relativePath
            //        return mmkv::MMKV::isFileValid(mmapID.UTF8String, path.UTF8String);
        } else {
            return mmkv::MMKV::isFileValid(mmapID.UTF8String);
        }
    }
    return NO;
}

+ (void)registerHandler:(id<MMKVHandler>)handler {
    SCOPEDLOCK(g_lock);
    g_callbackHandler = handler;

    if ([g_callbackHandler respondsToSelector:@selector(mmkvLogWithLevel:file:line:func:message:)]) {
        g_isLogRedirecting = true;
        // TODO: log redirecting
        // some logging before registerHandler
        MMKVInfo(@"pagesize:%zu", mmkv::DEFAULT_MMAP_SIZE);
    }
}

+ (void)unregiserHandler {
    SCOPEDLOCK(g_lock);
    g_callbackHandler = nil;
    g_isLogRedirecting = false;
}

+ (void)setLogLevel:(MMKVLogLevel)logLevel {
    mmkv::MMKV::setLogLevel((mmkv::MMKVLogLevel) logLevel);
}

- (uint32_t)migrateFromUserDefaults:(NSUserDefaults *)userDaults {
    NSDictionary *dic = [userDaults dictionaryRepresentation];
    if (dic.count <= 0) {
        MMKVInfo(@"migrate data fail, userDaults is nil or empty");
        return 0;
    }
    __block uint32_t count = 0;
    [dic enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull obj, BOOL *_Nonnull stop) {
        if ([key isKindOfClass:[NSString class]]) {
            NSString *stringKey = key;
            if ([MMKV tranlateData:obj key:stringKey kv:self]) {
                count++;
            }
        } else {
            MMKVWarning(@"unknown type of key:%@", key);
        }
    }];
    return count;
}

+ (BOOL)tranlateData:(id)obj key:(NSString *)key kv:(MMKV *)kv {
    if ([obj isKindOfClass:[NSString class]]) {
        return [kv setString:obj forKey:key];
    } else if ([obj isKindOfClass:[NSData class]]) {
        return [kv setData:obj forKey:key];
    } else if ([obj isKindOfClass:[NSDate class]]) {
        return [kv setDate:obj forKey:key];
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = obj;
        CFNumberType numberType = CFNumberGetType((CFNumberRef) obj);
        switch (numberType) {
            case kCFNumberCharType:
            case kCFNumberSInt8Type:
            case kCFNumberSInt16Type:
            case kCFNumberSInt32Type:
            case kCFNumberIntType:
            case kCFNumberShortType:
                return [kv setInt32:num.intValue forKey:key];
            case kCFNumberSInt64Type:
            case kCFNumberLongType:
            case kCFNumberNSIntegerType:
            case kCFNumberLongLongType:
                return [kv setInt64:num.longLongValue forKey:key];
            case kCFNumberFloat32Type:
                return [kv setFloat:num.floatValue forKey:key];
            case kCFNumberFloat64Type:
            case kCFNumberDoubleType:
                return [kv setDouble:num.doubleValue forKey:key];
            default:
                MMKVWarning(@"unknown number type:%ld, key:%@", (long) numberType, key);
                return NO;
        }
    } else if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]]) {
        return [kv setObject:obj forKey:key];
    } else {
        MMKVWarning(@"unknown type of key:%@", key);
    }
    return NO;
}

@end

static NSString *md5(NSString *value) {
    unsigned char md[MD5_DIGEST_LENGTH] = {0};
    char tmp[3] = {0}, buf[33] = {0};
    // TODO: namespace openssl & rename files
    MD5((unsigned char *) value.UTF8String, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding], md);
    for (int i = 0; i < MD5_DIGEST_LENGTH; i++) {
        sprintf(tmp, "%2.2x", md[i]);
        strcat(buf, tmp);
    }
    return [NSString stringWithCString:buf encoding:NSASCIIStringEncoding];
}

static NSString *encodeMmapID(NSString *mmapID) {
    static NSCharacterSet *specialCharacters = [NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|"];
    auto range = [mmapID rangeOfCharacterFromSet:specialCharacters];
    if (range.location != NSNotFound) {
        NSString *encodedID = md5(mmapID);
        return [SPECIAL_CHARACTER_DIRECTORY_NAME stringByAppendingFormat:@"/%@", encodedID];
    } else {
        return mmapID;
    }
}
