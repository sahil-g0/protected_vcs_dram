#include <stdio.h>
#include <stdbool.h>

#define QUEUESIZE 100
#define BATCHSIZE 5

// TIMINGS
#define tRCD     14 // ACT to READ
#define tCL      14 // READ to data burst start
#define tRAS     28 // ACT to PRE
#define tRP      14 // PRE duration
#define tRTP     8  // READ to PRE
#define tRRD_sg  4  // ACT to ACT same group
#define tRRD_dg  4  // ACT to ACT diff group
#define tFAW     16 // 1st ACT to 5th ACT
#define tRDRD_sg 7  // READ to READ same group
#define tRDRD_dg 4  // READ to READ diff group

// Define the request struct
struct request {
    int valid;
    int bank_group;
    int bank;
    int row;
    int col;
};

struct row_request {
    int valid;
    int bank_group;
    int bank;
    int row;
    int col[BATCHSIZE];
    int requests;
    int id;
};

struct bank_request {
    int valid;
    int bank_group;
    int bank;
    int rows[BATCHSIZE];
    int requests;
};

// Declare global arrays of struct request
struct request req_queue[QUEUESIZE];
struct request req_batch[BATCHSIZE];

// Function prototype (pass array of structs)
void scheduler(struct request req_batch[]);

void scheduler(struct request req_batch[]) {
    struct row_request batch_aliased[BATCHSIZE];
    //Alias the requests together if they are to the same row
    int row_counter=0;
    for(int i =0;i<BATCHSIZE;i++){
        bool found =false;
        for(int j =0;j<row_counter;j++){
            if((req_batch[i].bank_group==batch_aliased[j].bank_group)
                && (req_batch[i].bank==batch_aliased[j].bank)
                && (req_batch[i].row==batch_aliased[j].row)){
                found=true;
                batch_aliased[j].col[batch_aliased[j].requests]=req_batch[i].col;
                batch_aliased[j].requests++;
                break;
            }
        }
        if(!found){
            batch_aliased[row_counter].valid = true;
            batch_aliased[row_counter].bank_group=req_batch[i].bank_group;
            batch_aliased[row_counter].bank=req_batch[i].bank;
            batch_aliased[row_counter].row=req_batch[i].row;
            batch_aliased[row_counter].col[0]=req_batch[i].col;
            batch_aliased[row_counter].requests=1;
            batch_aliased[row_counter].id = row_counter+1;
            row_counter++;
        }
    }
    printf("ALIASED BATCH\n");
    for(int i =0;i<row_counter;i++){
        printf("ID %d: Bank Group %d Bank %d Row %d -> Columns: ",batch_aliased[i].id, batch_aliased[i].bank_group, 
            batch_aliased[i].bank, batch_aliased[i].row);
        for(int j=0;j<batch_aliased[i].requests;j++){
            printf("%d ",batch_aliased[i].col[j]);
        }
        printf("\n");
    }
    //Look for conflicting requests by making a bank requests queue
    struct bank_request row_conflicts[row_counter];
    int bank_counter= 0;
    for(int i =0;i<row_counter;i++){
        bool found =false;
        for(int j=0;j<bank_counter;j++){
            if(row_conflicts[j].bank_group == batch_aliased[i].bank_group
                && row_conflicts[j].bank == batch_aliased[i].bank){
                    found=true;
                    row_conflicts[j].rows[row_conflicts[j].requests]=batch_aliased[i].id;
                    row_conflicts[j].requests++;
                    break;
            }
        }
        if(!found){
            row_conflicts[bank_counter].valid = true;
            row_conflicts[bank_counter].bank_group = batch_aliased[i].bank_group;
            row_conflicts[bank_counter].bank = batch_aliased[i].bank;
            row_conflicts[bank_counter].rows[0]=batch_aliased[i].id;
            row_conflicts[bank_counter].requests=1;
            bank_counter++;
        }
    }
    printf("BANK REQUESTS BATCH\n");
    for(int i =0;i<bank_counter;i++){
        printf("%d: Bank Group %d Bank %d Row(s) ",i+1, row_conflicts[i].bank_group, 
            row_conflicts[i].bank);
        for(int j=0;j<row_conflicts[i].requests;j++){
            printf("%d ",row_conflicts[i].rows[j]);
        }
        printf("\n");
    }
    //schedule the conflicting rows
    printf("SCHEDULE:\n");
    
}

int main(void) {
    // prepare request batch
    req_batch[0].bank_group = 0;
    req_batch[0].bank = 0;
    req_batch[0].row = 1;
    req_batch[0].col = 6;
    req_batch[0].valid = 1;

    req_batch[1].bank_group = 0;
    req_batch[1].bank = 0;
    req_batch[1].row = 2;
    req_batch[1].col = 5;
    req_batch[1].valid = 1;

    req_batch[2].bank_group = 0;
    req_batch[2].bank = 0;
    req_batch[2].row = 1;
    req_batch[2].col = 3;
    req_batch[2].valid = 1;

    req_batch[3].bank_group = 0;
    req_batch[3].bank = 0;
    req_batch[3].row = 4;
    req_batch[3].col = 4;
    req_batch[3].valid = 1;

    req_batch[4].bank_group = 2;
    req_batch[4].bank = 1;
    req_batch[4].row = 2;
    req_batch[4].col = 2;
    req_batch[4].valid = 1;

    // Run scheduler
    scheduler(req_batch);
    return 0;
}
