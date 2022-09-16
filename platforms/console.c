// IO platform supporting line-based console IO on UNIX-y systems

// This file is designed to be concatenated to the generated runtime

// Protocol
// ---------------------------------------------------------------------
// Program halts with           Platform will
// --------------------------   ----------------------------------------
//
//  IO.do_output str (@_ rest)  1. Convert HVM-string str to C-string
//                              2. Print line to stdout
//                              3. Replace term with rest
//                              4. Tell runtime to continue
//
//  IO.do_input cont            1. Read a line from stdin
//                              2. Convert to HVM-string str
//                              3. Replace term with (cont str)
//                              4. Tell runtime to continue
//
//  IO.done e                   1. Read-back HVM-expression e to C-string
//                              2. Print to stdout
//                              3. Tell runtime to halt
//
//  <anything else>             Undefined behaviour.

// Other special constructors used
// --------------------------------------------
// Constructor      Used for
// ------------     ---------------------------
//  String.cons     Linked-list string encoding
//  String.nil      Linked-list string encoding

// Implementation
// --------------

// Programs may not use all the special constructors
// In that case, these #define s make the platfrom still compile

#ifndef _IO_DO_OUTPUT_
#define _IO_DO_OUTPUT_ -1
#endif
#ifndef _IO_DO_INPUT_
#define _IO_DO_INPUT_ -2
#endif
#ifndef _IO_DONE_
#define _IO_DONE_ -3
#endif
#ifndef _STRING_NIL_
#define _STRING_NIL_ -4
#endif
#ifndef _STRING_CONS_
#define _STRING_CONS_ -5
#endif


#include <stdio.h>
#include <sys/time.h>

struct PlatState {
    Worker* mem;
};

PlatState* io_setup(Worker* mem) {
    PlatState * state = malloc (sizeof (PlatState));
    state -> mem = mem;
    return state;
}

static char* str_TAG_DP0 = "DP0";
static char* str_TAG_DP1 = "DP1";
static char* str_TAG_VAR = "VAR";
static char* str_TAG_ARG = "ARG";
static char* str_TAG_ERA = "ERA";
static char* str_TAG_LAM = "LAM";
static char* str_TAG_APP = "APP";
static char* str_TAG_SUP = "SUP";
static char* str_TAG_CTR = "CTR";
static char* str_TAG_FUN = "FUN";
static char* str_TAG_OP2 = "OP2";
static char* str_TAG_NUM = "NUM";
static char* str_TAG_FLO = "FLO";
static char* str_TAG_NIL = "NIL";

static char* str_unknown = "???";


char * decode_tag(u64 tag){
    switch (tag) {
      case DP0: return str_TAG_DP0;     break;
      case DP1: return str_TAG_DP1;     break;
      case VAR: return str_TAG_VAR;     break;
      case ARG: return str_TAG_ARG;     break;
      case ERA: return str_TAG_ERA;     break;
      case LAM: return str_TAG_LAM;     break;
      case APP: return str_TAG_APP;     break;
      case SUP: return str_TAG_SUP;     break;
      case CTR: return str_TAG_CTR;     break;
      case FUN: return str_TAG_FUN;     break;
      case OP2: return str_TAG_OP2;     break;
      case NUM: return str_TAG_NUM;     break;
      case FLO: return str_TAG_FLO;     break;
      case NIL: return str_TAG_NIL;     break;
      default : return str_unknown;     break;
    }
}

char * decode_cid(PlatState* state, u64 cid){
    if (cid < id_to_name_size) {
        return id_to_name_data[cid];
    } else {
        return str_unknown;
    }
}

bool io_step(PlatState* state) {
    assert(get_tag(state->mem->node[0]) == CTR);
    u64 cid = get_ext(state->mem->node[0]);
    switch (cid) {

        case _IO_DONE_:
            printf("TODO -- handle IO.done");
            return false;
            break;

        case _IO_DO_OUTPUT_:
            printf("TODO -- handle IO.do_output");
            return false;
            break;

        case _IO_DO_INPUT_:
            printf("TODO -- handle IO.do_input");
            return false;
            break;

        default: // print debug info
            fprintf(stderr, "[Console IO platform] Illegal IO request!\n");
            fprintf(stderr, "node[0] cid: %s\n", decode_cid(state,cid));
            free(state);
            return false;
            break;
    }
}