//
//  persistence_stub.m
//
//  Avoid linking DarkSword's launchd RemoteCall persistence path (hangs on 17.3.1).
//  DarkSword still works; stashKRW should stay off.
//

#import "persistence.h"
#import <stdio.h>

bool transfer_krw_to_launchd(void) {
    printf("(persist-stub) transfer_krw_to_launchd skipped\n");
    return false;
}

bool recover_krw_primitives(void) {
    printf("(persist-stub) recover_krw_primitives unavailable\n");
    return false;
}
