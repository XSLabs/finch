/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The Objective-C OpenDirectory objects read one local account and query it by name. */
#import <OpenDirectory/OpenDirectory.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSError *error = nil;
        ODSession *session = [ODSession defaultSession];
        NSArray *nodes = [session nodeNamesAndReturnError:&error];
        printf("session %d local node listed %d\n", session != nil,
            [nodes containsObject:@"/Local/Default"]);

        ODNode *node = [ODNode nodeWithSession:session type:kODNodeTypeAuthentication error:&error];
        printf("authentication node %d\n", node != nil);
        NSString *name = NSUserName();
        ODRecord *record = [node recordWithRecordType:kODRecordTypeUsers name:name attributes:nil error:&error];
        NSArray *uids = [record valuesForAttribute:kODAttributeTypeUniqueID error:&error];
        printf("current user %d name %d uid %lu\n", record != nil,
            [record.recordName isEqualToString:name], (unsigned long)uids.count);

        ODQuery *query = [ODQuery queryWithNode:node forRecordTypes:kODRecordTypeUsers
            attribute:kODAttributeTypeRecordName matchType:kODMatchEqualTo queryValues:name
            returnAttributes:nil maximumResults:10 error:&error];
        NSArray *matches = [query resultsAllowingPartial:NO error:&error];
        printf("query %d matches %lu same %d\n", query != nil, (unsigned long)matches.count,
            [((ODRecord *)matches.firstObject).recordName isEqualToString:name]);
    }
    return 0;
}
