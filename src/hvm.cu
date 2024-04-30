// HVM-CUDA: an Interaction Combinator evaluator in CUDA.
// 
// # Format
// 
// An HVM net is a graph with 8 node types:
// - *       ::= ERAser node.
// - #N      ::= NUMber node.
// - @def    ::= REFerence node.
// - x       ::= VARiable node.
// - (a b)   ::= CONstructor node.
// - {a b}   ::= DUPlicator node.
// - <+ a b> ::= OPErator node.
// - ?<a b>  ::= SWItch node.
// 
// Nodes form a tree-like structure in memory. For example:
// 
//     ((* x) {x (y y)})
// 
// Represents a tree with 3 CON nodes, 1 ERA node and 4 VAR nodes.
// 
// A net consists of a root tree, plus list of redexes. Example:
// 
//     (a b)
//     & (b a) ~ (x (y *)) 
//     & {y x} ~ @foo
// 
// The net above has a root and 2 redexes (in the shape `& A ~ B`).
// 
// # Interactions 
// 
// Redexes are reduced via *interaction rules*:
// 
// ## 0. LINK
// 
//     a ~ b
//     ------ LINK
//     a ~> b
//
// ## 1. CALL
// 
//     @foo ~ B
//     ---------------
//     deref(@foo) ~ B
// 
// ## 2. VOID
// 
//     * ~ *
//     -----
//     void
// 
// ## 3. ERAS
// 
//     (A1 A2) ~ *
//     -----------
//     A1 ~ *
//     A2 ~ *
//     
// ## 4. ANNI (https://i.imgur.com/ASdOzbg.png)
//
//     (A1 A2) ~ (B1 B2)
//     -----------------
//     A1 ~ B1
//     A2 ~ B2
//     
// ## 5. COMM (https://i.imgur.com/gyJrtAF.png)
// 
//     (A1 A2) ~ {B1 B2}
//     -----------------
//     A1 ~ {x y}
//     A2 ~ {z w}
//     B1 ~ (x z)
//     B2 ~ (y w)
// 
// ## 6. OPER
// 
//     #A ~ <+ B1 B2>
//     --------------
//     if B1 is #B:
//       B2 ~ #A+B
//     else:
//       B1 ~ <+ #A B2>
//
// ## 7. SWIT
// 
//     #A ~ ?<B1 B2>
//     -------------
//     if A == 0:
//       B1 ~ (B2 *)
//     else:
//       B1 ~ (* (#A-1 B2))
// 
// # Interaction Table
// 
// | A\B |  VAR |  REF |  ERA |  NUM |  CON |  DUP |  OPR |  SWI |
// |-----|------|------|------|------|------|------|------|------|
// | VAR | LINK | CALL | LINK | LINK | LINK | LINK | LINK | LINK |
// | REF | CALL | VOID | VOID | VOID | CALL | CALL | CALL | CALL |
// | ERA | LINK | VOID | VOID | VOID | ERAS | ERAS | ERAS | ERAS |
// | NUM | LINK | VOID | VOID | VOID | ERAS | ERAS | OPER | CASE |
// | CON | LINK | CALL | ERAS | ERAS | ANNI | COMM | COMM | COMM |
// | DUP | LINK | CALL | ERAS | ERAS | COMM | ANNI | COMM | COMM |
// | OPR | LINK | CALL | ERAS | OPER | COMM | COMM | ANNI | COMM |
// | SWI | LINK | CALL | ERAS | CASE | COMM | COMM | COMM | ANNI |
// 
// # Definitions
// 
// A top-level definition is just a statically known closed net, also called a
// package. It is represented like a net, with a root and linked trees:
// 
//     @foo = (a b)
//     & @tic ~ (x a)
//     & @tac ~ (x b)
// 
// The statement above represents a definition, @foo, with the `(a b)` tree as
// the root, and two linked trees: `@tic ~ (x a)` and `@tac ~ (x b)`. When a
// REF is part of a redex, it expands to its complete value. For example:
// 
//     & @foo ~ ((* a) (* a))
// 
// Expands to:
// 
//     & (a0 b0) ~ ((* a) (* a))
//     & @tic ~ (x0 a0)
//     & @tac ~ (x0 b0)
// 
// As an optimization, `@foo ~ {a b}` and `@foo ~ *` will NOT expand; instead,
// it will copy or erase when it is safe to do so.
// 
// # Example Reduction
// 
// Consider the first example, which had 2 redexes. HVM is strongly confluent,
// thus, we can reduce them in any order, even in parallel, with no effect on
// the total work done. Below is its complete reduction:
// 
//     (a b) & (b a) ~ (x (y *)) & {y x} ~ @foo
//     ----------------------------------------------- ANNI
//     (a b) & b ~ x & a ~ (y *) & {y x} ~ @foo
//     ----------------------------------------------- COMM
//     (a b) & b ~ x & a ~ (y *) & y ~ @foo & x ~ @foo
//     ----------------------------------------------- LINK `y` and `x`
//     (a b) & b ~ @foo & a ~ (@foo *)
//     ----------------------------------------------- LINK `b` and `a`
//     ((@foo *) @foo)
//     ----------------------------------------------- CALL `@foo` (optional)
//     ((a0 b0) (a1 b1))
//     & @tic ~ (x0 a0) & @tac ~ (x0 b0)
//     & @tic ~ (x1 a1) & @tac ~ (x1 b1)
//     ----------------------------------------------- CALL `@tic` and `@tac`
//     ((a0 b0) (a1 b1))
//     & (k0 k0) ~ (x0 a0) & (k1 k1) ~ (x0 b0)
//     & (k2 k2) ~ (x1 a1) & (k3 k3) ~ (x1 b1)
//     ----------------------------------------------- ANNI (many in parallel)
//     ((a0 b0) (a1 b1))
//     & k0 ~ x0 & k0 ~ a0 & k1 ~ x0 & k1 ~ b0
//     & k2 ~ x1 & k2 ~ a1 & k3 ~ x1 & k3 ~ b1
//     ----------------------------------------------- LINK `kN`
//     ((a0 b0) (a1 b1))
//     & x0 ~ a0 & x0 ~ b0 & x1 ~ a1 & x1 ~ b1
//     ----------------------------------------------- LINK `xN`
//     ((a0 b0) (a1 b1)) & a0 ~ b0 & a1 ~ b1
//     ----------------------------------------------- LINK `aN`
//     ((b0 b0) (b1 b1))
// 
// # Memory Layout
// 
// An HVM-CUDA net includes a redex bag, a node buffer and a vars buffer:
//
//     LNet ::= { RBAG: [Pair], NODE: [Pair], VARS: [Port] }
// 
// A Pair consists of two Ports, representing a either a redex or a node:
// 
//     Pair ::= (Port, Port)
// 
// A Port consists of a tag and a value:
// 
//     Port ::= 3-bit tag + 13-bit val
// 
// There are 8 Tags:
// 
//     Tag ::=
//       | VAR ::= a variable
//       | REF ::= a reference
//       | ERA ::= an eraser
//       | NUM ::= numeric literal
//       | CON ::= a constructor
//       | DUP ::= a duplicator
//       | OPR ::= numeric binary op
//       | SWI ::= numeric switch
// 
// ## Memory Layout Example
// 
// Consider, again, the following net:
// 
//     (a b)
//     & (b a) ~ (x (y *)) 
//     & {y x} ~ @foo
// 
// In memory, it could be represented as, for example:
// 
// - RBAG | FST-TREE | SND-TREE
// - ---- | -------- | --------
// - 0800 | CON 0001 | CON 0002 // '& (b a) ~ (x (y *))'
// - 1800 | DUP 0005 | REF 0000 // '& {x y} ~ @foo'
// - ---- | -------- | --------
// - NODE | PORT-1   | PORT-2
// - ---- | -------- | --------
// - 0000 | CON 0001 |          // points to root node
// - 0001 | VAR 0000 | VAR 0001 // '(a b)' node (root)
// - 0002 | VAR 0001 | VAR 0000 // '(b a)' node
// - 0003 | VAR 0002 | CON 0004 // '(x (y *))' node
// - 0004 | VAR 0003 | DUP 0000 // '(y *)' node
// - 0005 | VAR 0003 | VAR 0002 // '{y x}' node
// - ---- | -------- | --------

#define INTERPRETED

#include <stdint.h>
#include <stdio.h>

// FIXME: pages can leak when the kernel reserves it but never writes anything

// Integers
// --------

typedef  uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef  int32_t i32;
typedef    float f32;
typedef   double f64;
typedef unsigned long long int u64;

// Configuration
// -------------

// Clocks per Second
const u64 S = 2520000000;

// Threads per Block
const u32 TPB_L2 = 8;
const u32 TPB    = 1 << TPB_L2;

// Blocks per GPU
const u32 BPG_L2 = 7;
const u32 BPG    = 1 << BPG_L2;

// Types
// -----

// Local Types
typedef u8  Tag;  // Tag  ::= 3-bit (rounded up to u8)
typedef u32 Val;  // Val  ::= 29-bit (rounded up to u32)
typedef u32 Port; // Port ::= Tag + Val (fits a u32)
typedef u64 Pair; // Pair ::= Port + Port (fits a u64)

// Rules
typedef u8 Rule; // Rule ::= 3-bit (rounded up to 8)

// Numbs
typedef u32 Numb; // Numb ::= 29-bit (rounded up to u32)

// Tags
const Tag VAR = 0x0; // variable
const Tag REF = 0x1; // reference
const Tag ERA = 0x2; // eraser
const Tag NUM = 0x3; // number
const Tag CON = 0x4; // constructor
const Tag DUP = 0x5; // duplicator
const Tag OPR = 0x6; // operator
const Tag SWI = 0x7; // switch

// Interaction Rule Values
const Rule LINK = 0x0;
const Rule CALL = 0x1;
const Rule VOID = 0x2;
const Rule ERAS = 0x3;
const Rule ANNI = 0x4;
const Rule COMM = 0x5;
const Rule OPER = 0x6;
const Rule SWIT = 0x7;

// Constants
const Port FREE = 0x00000000;
const Port ROOT = 0xFFFFFFF8;
const Port NONE = 0xFFFFFFFF;

// Numbers
const Tag SYM = 0x0;
const Tag U24 = 0x1;
const Tag I24 = 0x2;
const Tag F24 = 0x3;
const Tag ADD = 0x4;
const Tag SUB = 0x5;
const Tag MUL = 0x6;
const Tag DIV = 0x7;
const Tag REM = 0x8;
const Tag EQ  = 0x9;
const Tag NEQ = 0xA;
const Tag LT  = 0xB;
const Tag GT  = 0xC;
const Tag AND = 0xD;
const Tag OR  = 0xE;
const Tag XOR = 0xF;

// Thread Redex Bag Length
const u32 RLEN = 256; // max 32 redexes

// Thread Redex Bag
// It uses the same space to store two stacks: 
// - HI: a high-priotity stack, for shrinking reductions
// - LO: a low-priority stack, for growing reductions
struct RBag {
  u32  lk_end;
  Pair lk_buf[RLEN];
  u32  hi_end;
  Pair hi_buf[RLEN];
  u32  lo_ini;
  u32  lo_end;
  Pair lo_buf[RLEN];
};

// Local Net
const u32 L_NODE_LEN = 0x2000; // max 8196 nodes
const u32 L_VARS_LEN = 0x2000; // max 8196 vars
struct LNet {
  Pair node_buf[L_NODE_LEN];
  Port vars_buf[L_VARS_LEN];
};

// Global Net
const u32 G_PAGE_MAX = 0x10000 - 1; // max 65536 pages
const u32 G_NODE_LEN = G_PAGE_MAX * L_NODE_LEN; // max 536m nodes 
const u32 G_VARS_LEN = G_PAGE_MAX * L_VARS_LEN; // max 536m vars 
const u32 G_RBAG_LEN = TPB * BPG * RLEN; // max 2m redexes
struct GNet {
  u32  rbag_use_A; // total rbag redex count (buffer A)
  u32  rbag_use_B; // total rbag redex count (buffer B)
  Pair rbag_buf_A[G_RBAG_LEN]; // global redex bag (buffer A)
  Pair rbag_buf_B[G_RBAG_LEN]; // global redex bag (buffer B)
  Pair node_buf[G_NODE_LEN]; // global node buffer
  Port vars_buf[G_VARS_LEN]; // global vars buffer
  u32  page_use[G_PAGE_MAX]; // node count of each page
  u32  free_buf[G_PAGE_MAX]; // set of free pages
  u32  free_pop; // index to reserve a page
  u32  free_put; // index to release a page
  u64  itrs; // interaction count
};

// View Net: includes both GNet and LNet
struct Net {
  i32   l_node_dif; // delta node space
  i32   l_vars_dif; // delta vars space
  Pair *l_node_buf; // local node buffer values
  Port *l_vars_buf; // local vars buffer values
  u32  *g_rbag_use_A; // global rbag count (active buffer)
  u32  *g_rbag_use_B; // global rbag count (inactive buffer)
  Pair *g_rbag_buf_A; // global rbag values (active buffer)
  Pair *g_rbag_buf_B; // global rbag values (inactive buffer)
  Pair *g_node_buf; // global node buffer values
  Port *g_vars_buf; // global vars buffer values
  u32  *g_page_use; // usage counter of pages
  u32  *g_free_buf; // free pages indexes
  u32  *g_free_pop; // index to reserve a page
  u32  *g_free_put; // index to release a page
  u32   g_page_idx; // selected page index
};

// Thread Memory
struct TM {
  u32  page; // page index
  u32  nput; // node alloc index
  u32  vput; // vars alloc index
  u32  itrs; // interactions
  u32  nloc[32]; // node allocs
  u32  vloc[32]; // vars allocs
  RBag rbag; // tmem redex bag
};

// Top-Level Definition
struct Def {
  char name[32];
  bool safe;
  u32  rbag_len;
  u32  node_len;
  u32  vars_len;
  Port root;
  Pair rbag_buf[32];
  Pair node_buf[32];
};

// Book of Definitions
struct Book {
  u32 defs_len;
  Def defs_buf[256];
};

// Static Book
__device__ Book BOOK;

// Debugger
// --------

struct Show {
  char x[13];
};

__device__ __host__ void put_u16(char* B, u16 val);
__device__ __host__ Show show_port(Port port);
__device__ Show show_rule(Rule rule);
__device__ void print_rbag(RBag* rbag);
__device__ __host__ void print_net(Net* net);
__device__ void pretty_print_port(Net* net, Port port);
__device__ void pretty_print_rbag(Net* net, RBag* rbag);

// Utils
// -----

__device__ inline u32 TID() {
  return threadIdx.x;
}

__device__ inline u32 BID() {
  return blockIdx.x;
}

__device__ inline u32 GID() {
  return TID() + BID() * blockDim.x;
}

__device__ __host__ inline u32 div(u32 a, u32 b) {
  return (a + b - 1) / b;
}

// Port: Constructor and Getters
// -----------------------------

__device__ __host__ inline Port new_port(Tag tag, Val val) {
  return (val << 3) | tag;
}

__device__ __host__ inline Tag get_tag(Port port) {
  return port & 7;
}

__device__ __host__ inline Val get_val(Port port) {
  return port >> 3;
}

__device__ __host__ inline Val get_page(Val val) {
  return val / L_NODE_LEN;
}

// Pair: Constructor and Getters
// -----------------------------

__device__ __host__ inline Pair new_pair(Port fst, Port snd) {
  return ((u64)snd << 32) | fst;
}

__device__ __host__ inline Port get_fst(Pair pair) {
  return pair & 0xFFFFFFFF;
}

__device__ __host__ inline Port get_snd(Pair pair) {
  return pair >> 32;
}

// Utils
// -----

// Swaps two ports.
__device__ __host__ inline void swap(Port *a, Port *b) {
  Port x = *a; *a = *b; *b = x;
}

// Transposes an index over a matrix.
__device__ u32 transpose(u32 idx, u32 width, u32 height) {
  u32 old_row = idx / width;
  u32 old_col = idx % width;
  u32 new_row = old_col % height;
  u32 new_col = old_col / height + old_row * (width / height);
  return new_row * width + new_col;
}

// Returns true if all 'x' are true, block-wise
__device__ __noinline__ bool block_all(bool x) {
  __shared__ bool res;
  if (TID() == 0) res = true;
  __syncthreads();
  if (!x) res = false;
  __syncthreads();
  return res;
}

// Returns true if any 'x' is true, block-wise
__device__ __noinline__ bool block_any(bool x) {
  __shared__ bool res;
  if (TID() == 0) res = false;
  __syncthreads();
  if (x) res = true;
  __syncthreads();
  return res;
}

// Returns the sum of a value, block-wise
template <typename A>
__device__ __noinline__ A block_sum(A x) {
  __shared__ A res;
  if (TID() == 0) res = 0;
  __syncthreads();
  atomicAdd(&res, x);
  __syncthreads();
  return res;
}

// Returns the sum of a boolean, block-wise
__device__ __noinline__ u32 block_count(bool x) {
  __shared__ u32 res;
  if (TID() == 0) res = 0;
  __syncthreads();
  atomicAdd(&res, x);
  __syncthreads();
  return res;
}

// Prints a 4-bit value for each thread in a block
__device__ void block_print(u32 x) {
  __shared__ u8 value[TPB];

  value[TID()] = x;
  __syncthreads();

  if (TID() == 0) {
    for (u32 i = 0; i < TPB; ++i) {
      printf("%x", min(value[i],0xF));
    }
  }
  __syncthreads();
}


// Ports / Pairs / Rules
// ---------------------

// True if this port has a pointer to a node.
__device__ __host__ inline bool is_nod(Port a) {
  return get_tag(a) >= CON;
}

// True if this port is a variable.
__device__ __host__ inline bool is_var(Port a) {
  return get_tag(a) == VAR;
}

// Given two tags, gets their interaction rule. Uses a u64mask lookup table.
__device__ __host__ inline Rule get_rule(Port A, Port B) {
  const u64 x = 0b0111111010110110110111101110111010110000111100001111000100000010;
  const u64 y = 0b0000110000001100000011100000110011111110111111100010111000000000;
  const u64 z = 0b1111100011111000111100001111000011000000000000000000000000000000;
  const u64 i = ((u64)get_tag(A) << 3) | (u64)get_tag(B);
  return (Rule)((x>>i&1) | (y>>i&1)<<1 | (z>>i&1)<<2);
}

// Same as above, but receiving a pair.
__device__ __host__ inline Rule get_pair_rule(Pair AB) {
  return get_rule(get_fst(AB), get_snd(AB));
}

// Should we swap ports A and B before reducing this rule?
__device__ __host__ inline bool should_swap(Port A, Port B) {
  return get_tag(B) < get_tag(A);
}

// Gets a rule's priority
__device__ __host__ inline bool is_high_priority(Rule rule) {
  return (bool)((0b00011101 >> rule) & 1);
}

// Adjusts a newly allocated port.
__device__ inline Port adjust_port(Net* net, TM* tm, Port port) {
  Tag tag = get_tag(port);
  Val val = get_val(port);
  if (is_nod(port)) return new_port(tag, tm->nloc[val]);
  if (is_var(port)) return new_port(tag, tm->vloc[val]);
  return new_port(tag, val);
}

// Adjusts a newly allocated pair.
__device__ inline Pair adjust_pair(Net* net, TM* tm, Pair pair) {
  Port p1 = adjust_port(net, tm, get_fst(pair));
  Port p2 = adjust_port(net, tm, get_snd(pair));
  return new_pair(p1, p2);
}

// Words
// -----

// Constructor and getters for SYM (operation selector)
__device__ inline Numb new_sym(u32 val) {
  return ((val & 0xF) << 4) | SYM;
}

__device__ inline u32 get_sym(Numb word) {
  return (word >> 4) & 0xF;
}

// Constructor and getters for U24 (unsigned 24-bit integer)
__device__ inline Numb new_u24(u32 val) {
  return ((val & 0xFFFFFF) << 4) | U24;
}

__device__ inline u32 get_u24(Numb word) {
  return (word >> 4) & 0xFFFFFF;
}

// Constructor and getters for I24 (signed 24-bit integer)
__device__ inline Numb new_i24(i32 val) {
  return (((u32)val << 4) & 0xFFFFFF) | I24;
}

__device__ inline i32 get_i24(Numb word) {
  return (((word >> 4) & 0xFFFFFF) << 8) >> 8;
}

// Constructor and getters for F24 (24-bit float)
__device__ inline Numb new_f24(f32 val) {
  u32 bits = *(u32*)&val;
  u32 sign = (bits >> 31) & 0x1;
  i32 expo = ((bits >> 23) & 0xFF) - 127;
  u32 mant = bits & 0x7FFFFF;
  u32 uexp = expo + 63;
  u32 bts1 = (sign << 23) | (uexp << 16) | (mant >> 7);
  return (bts1 << 4) | F24;
}

__device__ inline f32 get_f24(Numb word) {
  u32 bits = (word >> 4) & 0xFFFFFF;
  u32 sign = (bits >> 23) & 0x1;
  u32 expo = (bits >> 16) & 0x7F;
  u32 mant = bits & 0xFFFF;
  i32 iexp = expo - 63;
  u32 bts0 = (sign << 31) | ((iexp + 127) << 23) | (mant << 7);
  u32 bts1 = (mant == 0 && iexp == -63) ? (sign << 31) : bts0;
  return *(f32*)&bts1;
}

// Flip flag
__device__ inline Tag get_typ(Numb word) {
  return word & 0xF;
}

__device__ inline bool get_flp(Numb word) {
  return ((word >> 29) & 1) == 1;
}

__device__ inline Numb set_flp(Numb word) {
  return word | 0x10000000;
}

__device__ inline Numb flp_flp(Numb word) {
  return word ^ 0x10000000;
}

// Partial application
__device__ inline Numb partial(Numb a, Numb b) {
  return b & 0xFFFFFFF0 | get_sym(a);
}

// Operate function
__device__ inline Numb operate(Numb a, Numb b) {
  if (get_flp(a) ^ get_flp(b)) {
    Numb t = a; a = b; b = t;
  }
  Tag at = get_typ(a);
  Tag bt = get_typ(b);
  if (at == SYM && bt == SYM) {
    return new_u24(0);
  }
  if (at == SYM && bt != SYM) {
    return partial(a, b);
  }
  if (at != SYM && bt == SYM) {
    return partial(b, a);
  }
  if (at >= ADD && bt >= ADD) {
    return new_u24(0);
  }
  if (at < ADD && bt < ADD) {
    return new_u24(0);
  }
  Tag op = (at >= ADD) ? at : bt;
  Tag ty = (at >= ADD) ? bt : at;
  switch (ty) {
    case U24: {
      u32 av = get_u24(a);
      u32 bv = get_u24(b);
      switch (op) {
        case ADD: return new_u24(av + bv);
        case SUB: return new_u24(av - bv);
        case MUL: return new_u24(av * bv);
        case DIV: return new_u24(av / bv);
        case REM: return new_u24(av % bv);
        case EQ:  return new_u24(av == bv);
        case NEQ: return new_u24(av != bv);
        case LT:  return new_u24(av < bv);
        case GT:  return new_u24(av > bv);
        case AND: return new_u24(av & bv);
        case OR:  return new_u24(av | bv);
        case XOR: return new_u24(av ^ bv);
        default:  return new_u24(0);
      }
    }
    case I24: {
      i32 av = get_i24(a);
      i32 bv = get_i24(b);
      switch (op) {
        case ADD: return new_i24(av + bv);
        case SUB: return new_i24(av - bv);
        case MUL: return new_i24(av * bv);
        case DIV: return new_i24(av / bv);
        case REM: return new_i24(av % bv);
        case EQ:  return new_i24(av == bv);
        case NEQ: return new_i24(av != bv);
        case LT:  return new_i24(av < bv);
        case GT:  return new_i24(av > bv);
        case AND: return new_i24(av & bv);
        case OR:  return new_i24(av | bv);
        case XOR: return new_i24(av ^ bv);
        default:  return new_i24(0);
      }
    }
    case F24: {
      f32 av = get_f24(a);
      f32 bv = get_f24(b);
      switch (op) {
        case ADD: return new_f24(av + bv);
        case SUB: return new_f24(av - bv);
        case MUL: return new_f24(av * bv);
        case DIV: return new_f24(av / bv);
        case REM: return new_f24(fmodf(av, bv));
        case EQ:  return new_u24(av == bv);
        case NEQ: return new_u24(av != bv);
        case LT:  return new_u24(av < bv);
        case GT:  return new_u24(av > bv);
        case AND: return new_f24(atan2f(av, bv));
        case OR:  return new_f24(logf(bv) / logf(av));
        case XOR: return new_f24(powf(av, bv));
        default:  return new_f24(0);
      }
    }
    default: return new_u24(0);
  }
}

// RBag
// ----

__device__ RBag rbag_new() {
  RBag rbag;
  rbag.lk_end = 0;
  rbag.hi_end = 0;
  rbag.lo_ini = 0;
  rbag.lo_end = 0;
  return rbag;
}

__device__ void push_redex(TM* tm, Pair redex) {
  Rule rule = get_pair_rule(redex);
  if (is_high_priority(rule)) {
    tm->rbag.hi_buf[tm->rbag.hi_end++ % RLEN] = redex;
  } else {
    tm->rbag.lo_buf[tm->rbag.lo_end++ % RLEN] = redex;
  }
}

__device__ Pair pop_redex(TM* tm) {
  if (tm->rbag.hi_end > 0) {
    return tm->rbag.hi_buf[(--tm->rbag.hi_end) % RLEN];
  } else if (tm->rbag.lo_end - tm->rbag.lo_ini > 0) {
    return tm->rbag.lo_buf[(--tm->rbag.lo_end) % RLEN];
  } else {
    return 0; // FIXME: is this ok?
  }
}

__device__ u32 rbag_len(RBag* rbag) {
  return rbag->hi_end + rbag->lo_end - rbag->lo_ini;
}

__device__ u32 rbag_has_highs(RBag* rbag) {
  return rbag->hi_end > 0;
}

// TM
// --

__device__ TM tmem_new() {
  TM tm;
  tm.rbag = rbag_new();
  tm.nput = threadIdx.x;
  tm.vput = threadIdx.x;
  tm.itrs = 0;
  return tm;
}

// Net
// ----

__device__ Net vnet_new(GNet* gnet, void* smem, u32 turn) {
  Net net;
  net.l_node_dif   = 0;
  net.l_vars_dif   = 0;
  net.l_node_buf   = ((LNet*)smem)->node_buf;
  net.l_vars_buf   = ((LNet*)smem)->vars_buf;
  net.g_rbag_use_A = turn % 2 == 0 ? &gnet->rbag_use_A : &gnet->rbag_use_B;
  net.g_rbag_use_B = turn % 2 == 0 ? &gnet->rbag_use_B : &gnet->rbag_use_A;
  net.g_rbag_buf_A = turn % 2 == 0 ? gnet->rbag_buf_A : gnet->rbag_buf_B;
  net.g_rbag_buf_B = turn % 2 == 0 ? gnet->rbag_buf_B : gnet->rbag_buf_A;
  net.g_node_buf   = gnet->node_buf;
  net.g_vars_buf   = gnet->vars_buf;
  net.g_page_use   = gnet->page_use;
  net.g_free_buf   = gnet->free_buf;
  net.g_free_pop   = &gnet->free_pop;
  net.g_free_put   = &gnet->free_put;
  net.g_page_idx   = 0xFFFFFFFF;
  return net;
}

// Reserves a page.
__device__ u32 reserve_page(Net* net) {
  u32 free_idx = atomicAdd(net->g_free_pop, 1);
  u32 page_idx = atomicExch(&net->g_free_buf[free_idx % G_PAGE_MAX], NONE);
  return page_idx;
}

// Releases a page.
__device__ void release_page(Net* net, u32 page) {
  u32 free_idx = atomicAdd(net->g_free_put, 1);
  net->g_free_buf[free_idx % G_PAGE_MAX] = page;
}

// If page is on global, decreases its length.
__device__ void decrease_page(Net* net, u32 page) {
  if (page != net->g_page_idx) {
    u32 prev_len = atomicSub(&net->g_page_use[page], 1);
    if (prev_len == 1) {
      release_page(net, page);
    }
  }
}

// Stores a new node on global.
__device__ inline void node_create(Net* net, u32 loc, Pair val) {
  if (get_page(loc) == net->g_page_idx) {
    net->l_node_dif += 1;
    //if (GID() == 0) printf("inc-node %d\n", *net->l_node_dif);
    atomicExch(&net->l_node_buf[loc - L_NODE_LEN*net->g_page_idx], val);
  } else {
    __builtin_unreachable(); // can't create outside of local page
  }
}

// Stores a var on global.
__device__ inline void vars_create(Net* net, u32 var, Port val) {
  if (get_page(var) == net->g_page_idx) {
    net->l_vars_dif += 1;
    //if (GID() == 0) printf("inc-vars %d\n", *net->l_vars_dif);
    atomicExch(&net->l_vars_buf[var - L_VARS_LEN*net->g_page_idx], val);
  } else {
    __builtin_unreachable(); // can't create outside of local page
  }
}

// Reads a node from global.
__device__ __host__ inline Pair node_load(Net* net, u32 loc) {
  if (get_page(loc) == net->g_page_idx) {
    return net->l_node_buf[loc - L_NODE_LEN*net->g_page_idx];
  } else {
    return net->g_node_buf[loc];
  }
}

// Reads a var from global.
__device__ __host__ inline Port vars_load(Net* net, u32 var) {
  if (get_page(var) == net->g_page_idx) {
    return net->l_vars_buf[var - L_VARS_LEN*net->g_page_idx];
  } else {
    return net->g_vars_buf[var];
  }
}

// Stores a node on global.
__device__ inline void node_store(Net* net, u32 loc, Pair val) {
  if (get_page(loc) == net->g_page_idx) {
    net->l_node_buf[loc - L_NODE_LEN*net->g_page_idx] = val;
  } else {
    net->g_node_buf[loc] = val;
  }
}

// Stores a var on global.
__device__ inline void vars_store(Net* net, u32 var, Port val) {
  if (get_page(var) == net->g_page_idx) {
    net->l_vars_buf[var - L_VARS_LEN*net->g_page_idx] = val;
  } else {
    net->g_vars_buf[var] = val;
  }
}

// Exchanges a node on global by a value. Returns old.
__device__ inline Pair node_exchange(Net* net, u32 loc, Pair val) {  
  if (get_page(loc) == net->g_page_idx) {
    return atomicExch(&net->l_node_buf[loc - L_NODE_LEN*net->g_page_idx], val);
  } else {
    return atomicExch(&net->g_node_buf[loc], val);
  }
}

// Exchanges a var on global by a value. Returns old.
__device__ inline Port vars_exchange(Net* net, u32 var, Port val) {
  if (get_page(var) == net->g_page_idx) {
    return atomicExch(&net->l_vars_buf[var - L_VARS_LEN*net->g_page_idx], val);
  } else {
    return atomicExch(&net->g_vars_buf[var], val);
  }
}

// Takes a node.
__device__ inline Pair node_take(Net* net, u32 loc) {
  if (get_page(loc) == net->g_page_idx) {
    net->l_node_dif -= 1;
    //if (GID() == 0) printf("dec-node %d\n", *net->l_node_dif);
    return atomicExch(&net->l_node_buf[loc - L_NODE_LEN*net->g_page_idx], 0);
  } else {
    decrease_page(net, get_page(loc));
    return atomicExch(&net->g_node_buf[loc], 0);
  }
}

// Takes a var.
__device__ inline Port vars_take(Net* net, u32 var) {
  if (get_page(var) == net->g_page_idx) {
    net->l_vars_dif -= 1;
    //if (GID() == 0) printf("dec-vars %d\n", *net->l_vars_dif);
    return atomicExch(&net->l_vars_buf[var - L_VARS_LEN*net->g_page_idx], 0);
  } else {
    decrease_page(net, get_page(var));
    return atomicExch(&net->g_vars_buf[var], 0);
  }
}

// GNet
// ----

// Initializes a Global Net.
__global__ void gnet_init(GNet* gnet) {
  // Adds all pages to the free buffer.
  if (GID() < G_PAGE_MAX) {
    gnet->free_buf[GID()] = GID();
  }
  // Creates root variable.
  gnet->vars_buf[get_val(ROOT)] = NONE;
}

// Allocator
// ---------

// Allocates empty slots in an array.
template <typename A>
__device__ u32 alloc(u32* idx, u32* res, u32 num, A* arr, u32 len, u32 add) {
  u32 got = 0;
  u32 lps = 0;
  while (got < num) {
    A elem = arr[*idx];
    if (elem == 0 && *idx > 0) {
      res[got++] = *idx + add;
    }
    *idx = (*idx + TPB) % len;
    if (++lps >= len / TPB) {
      return 0;
    }
  }
  return got;
}

// Allocates just 1 slot from node buffer.
__device__ u32 node_alloc_1(Net* net, TM* tm, u32* lps) {
  u32* idx = &tm->nput;
  while (true) {
    Pair elem = net->l_node_buf[*idx];
    u32 index = *idx + L_NODE_LEN*net->g_page_idx;
    *idx = (*idx + TPB) % L_NODE_LEN;
    if ((*lps)++ >= L_VARS_LEN / TPB) {
      return 0;
    }
    if (elem == 0 && index > 0) {
      return index;
    }
  }
}

// Allocates just 1 slot from vars buffer.
__device__ u32 vars_alloc_1(Net* net, TM* tm, u32* lps) {
  u32* idx = &tm->vput;
  while (true) {
    Port elem = net->l_vars_buf[*idx];
    u32 index = *idx + L_VARS_LEN*net->g_page_idx;
    *idx = (*idx + TPB) % L_VARS_LEN;
    if ((*lps)++ >= L_VARS_LEN / TPB) {
      return 0;
    }
    if (elem == 0 && index > 0) {
      return index;
    }
  }
}

// Gets the necessary resources for an interaction.
__device__ bool get_resources(Net* net, TM* tm, u8 need_rbag, u8 need_node, u8 need_vars) {
  u32 got_rbag = min(RLEN - (tm->rbag.lo_end - tm->rbag.lo_ini), RLEN - tm->rbag.hi_end);
  u32 got_node = alloc(&tm->nput, tm->nloc, need_node, net->l_node_buf, L_NODE_LEN, L_NODE_LEN*net->g_page_idx);
  u32 got_vars = alloc(&tm->vput, tm->vloc, need_vars, net->l_vars_buf, L_VARS_LEN, L_VARS_LEN*net->g_page_idx);
  return got_rbag >= need_rbag && got_node >= need_node && got_vars >= need_vars;
}

// Linking
// -------

// Finds a variable's value.
__device__ inline Port enter(Net* net, TM* tm, Port var) {
  // While `B` is VAR: extend it (as an optimization)
  while (get_tag(var) == VAR) {
    // Takes the current `var` substitution as `val`
    Port val = vars_exchange(net, get_val(var), NONE);
    // If there was no `val`, stop, as there is no extension
    if (val == NONE) {
      break;
    }
    // Sanity check
    if (val == 0) {
      //printf("UNREACHABLE\n");
      __builtin_unreachable();
    }
    // Otherwise, delete `B` (we own both) and continue
    vars_take(net, get_val(var));
    var = val;
  }
  return var;
}

// Atomically Links `A ~ B`.
__device__ void link(Net* net, TM* tm, Port A, Port B) {
  //printf("LINK %s ~> %s\n", show_port(A).x, show_port(B).x);
  
  // Attempts to directionally point `A ~> B`
  while (true) {
    // If `A` is PRI: swap `A` and `B`, and continue
    if (get_tag(A) != VAR) {
      Port X = A; A = B; B = X;
    }

    // If `A` is PRI: create the `A ~ B` redex
    if (get_tag(A) != VAR) {
      push_redex(tm, new_pair(A, B)); // TODO: move global ports to local
      break;
    }

    // While `B` is VAR: extend it (as an optimization)
    B = enter(net, tm, B);

    // Since `A` is VAR: point `A ~> B`.
    if (true) {
      // If a local node/var would leak to global, delay it
      if ( (is_nod(B) || is_var(B))
        && get_page(get_val(A)) != net->g_page_idx
        && get_page(get_val(B)) == net->g_page_idx) {
        tm->rbag.lk_buf[tm->rbag.lk_end++] = new_pair(A, B);
        break;
      }
      // Stores `A -> B`, taking the current `A` subst as `A'`
      Port A_ = vars_exchange(net, get_val(A), B);
      // If there was no `A'`, stop, as we lost B's ownership
      if (A_ == NONE) {
        break;
      }
      // Sanity check
      if (A_ == 0) {
        //printf("UNREACHABLE\n");
        __builtin_unreachable();
      }
      // Otherwise, delete `A` (we own both) and link `A' ~ B`
      vars_take(net, get_val(A));
      A = A_;
    }
  }
}

// Links `A ~ B` (as a pair).
__device__ void link_pair(Net* net, TM* tm, Pair AB) {
  link(net, tm, get_fst(AB), get_snd(AB));
}

// Sharing
// -------

// Sends redex to a friend local thread, when it is starving.
__device__ void share_redexes(TM* tm) {
  __shared__ Pair pool[TPB];
  Pair send, recv;
  u32*  ini = &tm->rbag.lo_ini;
  u32*  end = &tm->rbag.lo_end;
  Pair* bag = tm->rbag.lo_buf;
  for (u32 off = 1; off < 32; off *= 2) {
    send = (*end - *ini) > 1 ? bag[*ini%RLEN] : 0;
    recv = __shfl_xor_sync(__activemask(), send, off);
    if (!send &&  recv) bag[((*end)++)%RLEN] = recv;
    if ( send && !recv) ++(*ini);
  }
  for (u32 off = 32; off < TPB; off *= 2) {
    u32 a = TID();
    u32 b = a ^ off;
    send = (*end - *ini) > 1 ? bag[*ini%RLEN] : 0;
    pool[a] = send;
    __syncthreads();
    recv = pool[b];
    if (!send &&  recv) bag[((*end)++)%RLEN] = recv;
    if ( send && !recv) ++(*ini);
  }
}

// Interactions
// ------------

// The Link Interaction.
__device__ bool interact_link(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, 1, 0, 0)) {
    return false;
  }

  // Links.
  link_pair(net, tm, new_pair(a, b));

  return true;
}

// The Call Interaction.
#ifdef COMPILED
///COMPILED_INTERACT_CALL///
#else
__device__ bool interact_eras(Net* net, TM* tm, Port a, Port b);
__device__ bool interact_call(Net* net, TM* tm, Port a, Port b) {
  // Loads Definition.
  u32 fid  = get_val(a);
  Def* def = &BOOK.defs_buf[fid];

  // Copy Optimization.
  if (def->safe && get_tag(b) == DUP) {
    return interact_eras(net, tm, a, b);
  }

  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, def->rbag_len + 1, def->node_len, def->vars_len)) {
    return false;
  }

  // Stores new vars.
  for (u32 i = 0; i < def->vars_len; ++i) {
    vars_create(net, tm->vloc[i], NONE);
  }

  // Stores new nodes.  
  for (u32 i = 0; i < def->node_len; ++i) {
    node_create(net, tm->nloc[i], adjust_pair(net, tm, def->node_buf[i]));
  }

  // Links.
  link_pair(net, tm, new_pair(b, adjust_port(net, tm, def->root)));
  for (u32 i = 0; i < def->rbag_len; ++i) {
    link_pair(net, tm, adjust_pair(net, tm, def->rbag_buf[i]));
  }

  return true;
}
#endif

// The Void Interaction.
__device__ bool interact_void(Net* net, TM* tm, Port a, Port b) {
  return true;
}

// The Eras Interaction.
__device__ bool interact_eras(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, 2, 0, 0)) {
    return false;
  }

  // Checks availability
  //if (node_load(net,get_val(b)) == 0) {
    //printf("[%04x] unavailable5: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(b).x);
    //return false;
  //}

  // Loads ports.
  Pair B  = node_take(net, get_val(b));
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);

  //if (B == 0) printf("[%04x] ERROR2: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(b).x);

  // Links.
  link_pair(net, tm, new_pair(a, B1));
  link_pair(net, tm, new_pair(a, B2));

  return true;
}

// The Anni Interaction.
__device__ bool interact_anni(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, 2, 0, 0)) {
    return false;
  }

  // Loads ports.
  Pair A  = node_take(net, get_val(a));
  Port A1 = get_fst(A);
  Port A2 = get_snd(A);
  Pair B  = node_take(net, get_val(b));
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);

  //if (A == 0) printf("[%04x] ERROR3: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(a).x);
  //if (B == 0) printf("[%04x] ERROR4: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(b).x);

  // Links.
  link_pair(net, tm, new_pair(A1, B1));
  link_pair(net, tm, new_pair(A2, B2));

  return true;
}

// The Comm Interaction.
__device__ bool interact_comm(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, 4, 4, 4)) {
    return false;
  }

  // Loads ports.
  Pair A  = node_take(net, get_val(a));
  Port A1 = get_fst(A);
  Port A2 = get_snd(A);
  Pair B  = node_take(net, get_val(b));
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);

  //if (A == 0) printf("[%04x] ERROR5: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(a).x);
  //if (B == 0) printf("[%04x] ERROR6: %s\n", threadIdx.x+blockIdx.x*blockDim.x, show_port(b).x);

  // Stores new vars.
  vars_create(net, tm->vloc[0], NONE);
  vars_create(net, tm->vloc[1], NONE);
  vars_create(net, tm->vloc[2], NONE);
  vars_create(net, tm->vloc[3], NONE);

  // Stores new nodes.
  node_create(net, tm->nloc[0], new_pair(new_port(VAR, tm->vloc[0]), new_port(VAR, tm->vloc[1])));
  node_create(net, tm->nloc[1], new_pair(new_port(VAR, tm->vloc[2]), new_port(VAR, tm->vloc[3])));
  node_create(net, tm->nloc[2], new_pair(new_port(VAR, tm->vloc[0]), new_port(VAR, tm->vloc[2])));
  node_create(net, tm->nloc[3], new_pair(new_port(VAR, tm->vloc[1]), new_port(VAR, tm->vloc[3])));

  // Links.
  link_pair(net, tm, new_pair(A1, new_port(get_tag(b), tm->nloc[0])));
  link_pair(net, tm, new_pair(A2, new_port(get_tag(b), tm->nloc[1])));
  link_pair(net, tm, new_pair(B1, new_port(get_tag(a), tm->nloc[2])));
  link_pair(net, tm, new_pair(B2, new_port(get_tag(a), tm->nloc[3])));

  return true;
}

// The Oper Interaction.  
__device__ bool interact_oper(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.
  if (!get_resources(net, tm, 1, 1, 0)) {
    return false;
  }

  // Loads ports.
  Val  av = get_val(a);
  Pair B  = node_take(net, get_val(b));
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);
     
  // Performs operation.
  if (get_tag(B1) == NUM) {
    Val  bv = get_val(B1);
    Numb cv = operate(av, bv);
    link_pair(net, tm, new_pair(B2, new_port(NUM, cv))); 
  } else {
    node_create(net, tm->nloc[0], new_pair(new_port(get_tag(a), flp_flp(av)), B2));
    link_pair(net, tm, new_pair(B1, new_port(OPR, tm->nloc[0])));
  }


  return true;  
}

// The Swit Interaction.
__device__ bool interact_swit(Net* net, TM* tm, Port a, Port b) {
  // Allocates needed nodes and vars.  
  if (!get_resources(net, tm, 1, 2, 0)) {
    return false;
  }

  // Loads ports.
  u32  av = get_u24(get_val(a));
  Pair B  = node_take(net, get_val(b));
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);
 
  // Stores new nodes.
  if (av == 0) {
    node_create(net, tm->nloc[0], new_pair(B2, new_port(ERA,0)));
    link_pair(net, tm, new_pair(new_port(CON, tm->nloc[0]), B1));
  } else {
    node_create(net, tm->nloc[0], new_pair(new_port(ERA,0), new_port(CON, tm->nloc[1])));
    node_create(net, tm->nloc[1], new_pair(new_port(NUM, new_u24(av-1)), B2));
    link_pair(net, tm, new_pair(new_port(CON, tm->nloc[0]), B1));
  }

  return true;
}

// Pops a local redex and performs a single interaction.
__device__ bool interact(Net* net, TM* tm) {
  // Pops a redex.
  Pair redex = pop_redex(tm);

  // If there is no redex, stop.
  if (redex != 0) {
    // Gets redex ports A and B.
    Port a = get_fst(redex);
    Port b = get_snd(redex);

    // Gets the rule type.
    Rule rule = get_rule(a, b);

    //if (tid == 0) {
      //printf("[%04x] REDUCE %s ~ %s | %s\n", tid, show_port(a).x, show_port(b).x, show_rule(rule).x);
    //}

    // Used for root redex.
    if (get_tag(a) == REF && b == ROOT) {
      rule = CALL;
    // Swaps ports if necessary.
    } else if (should_swap(a,b)) {
      swap(&a, &b);
    }

    // Dispatches interaction rule.
    bool success;
    switch (rule) {
      case LINK: success = interact_link(net, tm, a, b); break;
      case CALL: success = interact_call(net, tm, a, b); break;
      case VOID: success = interact_void(net, tm, a, b); break;
      case ERAS: success = interact_eras(net, tm, a, b); break;
      case ANNI: success = interact_anni(net, tm, a, b); break;
      case COMM: success = interact_comm(net, tm, a, b); break;
      case OPER: success = interact_oper(net, tm, a, b); break;
      case SWIT: success = interact_swit(net, tm, a, b); break;
    }

    // If error, pushes redex back.
    if (!success) {
      push_redex(tm, redex);
      return false;
    // Else, increments the interaction count.
    } else if (rule != LINK) {
      tm->itrs += 1;
    }
  }

  return true;
}

// RBag Save/Load
// --------------

// Moves redexes from shared memory to global bag
__device__ u32 save_redexes(Net* net, TM *tm, u32 turn) {
  u32 bag = transpose(GID(), TPB, BPG);
  u32 idx = 0;
  // FIXME: prevent this by making lo/hi half as big
  if (rbag_len(&tm->rbag) >= RLEN) {
    printf("ERROR: CAN'T SAVE RBAG LEN > %d\n", RLEN);
  }
  // Moves low-priority redexes
  for (u32 i = tm->rbag.lo_ini; i < tm->rbag.lo_end; ++i) {
    net->g_rbag_buf_B[bag * RLEN + (idx++)] = tm->rbag.lo_buf[i % RLEN];
  }
  // Moves high-priority redexes
  for (u32 i = 0; i < tm->rbag.hi_end; ++i) {
    net->g_rbag_buf_B[bag * RLEN + (idx++)] = tm->rbag.hi_buf[i];
  }
  // Updates global redex counter
  atomicAdd(net->g_rbag_use_B, rbag_len(&tm->rbag));
}

// Loads redexes from global bag to shared memory
__device__ u32 load_redexes(Net* net, TM *tm, u32 turn) {
  u32 bag = GID();
  for (u32 i = 0; i < RLEN; ++i) {
    Pair redex = atomicExch(&net->g_rbag_buf_A[bag * RLEN + i], 0);
    if (redex != 0) {
      push_redex(tm, redex);
    } else {
      break;
    }
  }
}

// Page Save/Load
// --------------

// Reserves a new page to be used by this block
__device__ bool load_page(Net* net, TM* tm) {
  __shared__ u32 got_page;
  if (TID() == 0) {
    got_page = reserve_page(net);
  }
  __syncthreads();
  net->g_page_idx = got_page;
  if (net->g_page_idx >= G_PAGE_MAX) {
    return false;
  }
  return true;
}

// Moves local page to global net
__device__ u32 save_page(Net* net, TM* tm) {
  u32 node_count = 0;
  u32 vars_count = 0;
  // Move nodes to global
  for (u32 i = TID(); i < L_NODE_LEN; i += TPB) {
    // Gets node from local buffer
    Pair node = atomicExch(&net->l_node_buf[i], 0);
    if (node != 0) {
      // Moves to global buffer
      Pair old = atomicExch(&net->g_node_buf[L_NODE_LEN*net->g_page_idx+i], node);
      // Increase the page's size count
      node_count += 1;
      // Sanity check
      if (old != 0) {
        //printf("UNREACHABLE\n");
        __builtin_unreachable();
      }
    }
  }
  // Move vars to global
  for (u32 i = TID(); i < L_VARS_LEN; i += TPB) {
    // Take a var from local buffer 
    Port var = atomicExch(&net->l_vars_buf[i], 0);
    if (var != 0) {
      // Moves to global buffer
      Pair old = atomicExch(&net->g_vars_buf[L_VARS_LEN*net->g_page_idx+i], var);
      // Increase the page's size count
      vars_count += 1;
      // Sanity check
      if (old != 0) {
        //printf("UNREACHABLE\n");
        __builtin_unreachable();
      }
    }
  }
  // Pushes leaked links
  while (tm->rbag.lk_end > 0) {
    Pair redex = tm->rbag.lk_buf[--tm->rbag.lk_end];
    push_redex(tm, redex);
    //link(net, tm, get_fst(redex), get_snd(redex), true);
  }
  // Resets local page counters
  net->l_node_dif = 0;
  net->l_vars_dif = 0;
  // Updates global page length
  atomicAdd(&net->g_page_use[net->g_page_idx], node_count + vars_count);
  return node_count + vars_count;
}

// Evaluator
// ---------

__global__ void swap_rbuf(GNet* gnet, u32 turn) {
  if (turn % 2 == 0) {
    gnet->rbag_use_A = 0;
  } else {
    gnet->rbag_use_B = 0;
  }
  // no need to swap buf (already zeroed)
}

__global__ void evaluator(GNet* gnet, u32 turn) {
  extern __shared__ char shared_mem[]; // 96 KB
  __shared__ bool halt; // halting flag

  // Local State
  u32  tick = 0; // current tick
  u32  sv_t = 0; // next tick to save page
  u32  sv_a = 1; // how much to add to sv_t
  bool fail = false; // have we failed

  // Thread Memory
  TM tm = tmem_new();

  // Net (Local-Global View)
  Net net = vnet_new(gnet, shared_mem, turn);

  // Loads Redexes
  load_redexes(&net, &tm, turn);

  // Aborts if empty
  if (block_all(rbag_len(&tm.rbag) == 0)) {
    return;
  }

  // Constants
  const u64  INIT = clock64(); // initial time
  const u64  REPS = 13; // log2 of number of loops
  const bool GROW = *net.g_rbag_use_A < TPB*BPG; // expanding rbag?

  // Allocates Page
  if (!load_page(&net, &tm)) {
    // FIXME: treat this
    if (TID() == 0) {
      printf("[%04x] OOM\n", GID());
    }
    return;
  }

  // Interaction Loop
  for (tick = 0; tick < 1 << REPS; ++tick) {
    // Performs some interactions
    fail = !interact(&net, &tm);
    while (!fail && rbag_has_highs(&tm.rbag)) {
      fail = fail || !interact(&net, &tm);
    }

    //if (!TID()) printf("TICK %d\n", i);
    //block_print(rbag_len(&tm.rbag));
    //if (!TID()) printf("\n");
    //__syncthreads();

    // Shares a redex with neighbor thread
    if (TPB > 1 && tick % (1<<(tick/(1<<(REPS-5)))) == 0) {
      share_redexes(&tm);
    }

    //block_print(rbag_len(&tm.rbag));
    //if (!TID()) printf("\n");
    //__syncthreads();

    // If the local page is more than half full, quit
    if (tick == sv_t) {
      u32 actv = block_count(rbag_len(&tm.rbag) > 0);
      i32 ndif = block_sum(net.l_node_dif);
      i32 vdif = block_sum(net.l_vars_dif);
      u32 thrs = L_NODE_LEN / TPB / 2 * actv;
      if (actv == 0) {
        break;
      } else if (ndif > thrs || vdif > thrs) {
        save_page(&net, &tm);
        load_page(&net, &tm);
        //break; // TODO: don't quit; save page and continue!
      } else {
        sv_a *= 2;
      }
      sv_t += sv_a; 
    }

    // If grow-mode and all threads are full, halt
    if (GROW && block_all(rbag_len(&tm.rbag) > 0)) {
      break;
    }
  }

  // Moves vars+node to global
  u32 saved = save_page(&net, &tm);

  // Moves rbag to global
  save_redexes(&net, &tm, turn);

  // Stores rewrites
  atomicAdd(&gnet->itrs, tm.itrs);

  //u32 ITRS = block_sum(tm.itrs);
  //u32 RLEN = block_sum(rbag_len(&tm.rbag));
  //u32 SAVE = block_sum(saved);
  //u32 FAIL = block_sum((u32)fail);
  //u32 LOOP = block_sum((u32)tick);
  //i32 NDIF = block_sum(net.l_node_dif);
  //i32 VDIF = block_sum(net.l_vars_dif);
  //f64 TIME = (f64)(clock64() - INIT) / (f64)S;
  //f64 MIPS = (f64)ITRS / TIME / (f64)1000000.0;
  //if (TID() == 0) {
    //printf("%04x:[%02x]: ITRS=%d LOOP=%d RLEN=%d SAVE=%d NDIF=%d VDIF=%d FAIL=%d TIME=%f MIPS=%.0f\n", turn, BID(), ITRS, LOOP, RLEN, SAVE, NDIF, VDIF, FAIL, TIME, MIPS);
  //}

}

u32 get_rbag_len(GNet* gnet, u32 turn) {
  u32 rbag_use;
  if (turn % 2 == 0) {
    cudaMemcpy(&rbag_use, &gnet->rbag_use_B, sizeof(u32), cudaMemcpyDeviceToHost);
  } else {
    cudaMemcpy(&rbag_use, &gnet->rbag_use_A, sizeof(u32), cudaMemcpyDeviceToHost);
  }
  return rbag_use;
}

// Book Loader
// -----------

void book_load(u32* buf, Book* book) {
  // Reads defs_len
  book->defs_len = *buf++;

  //printf("len %d\n", book->defs_len);

  // Parses each def
  for (u32 i = 0; i < book->defs_len; ++i) {
    // Reads fid
    u32 fid = *buf++;

    // Gets def
    Def* def = &book->defs_buf[fid];
    
    // Reads name
    memcpy(def->name, buf, 32);
    buf += 8;

    // Reads safe flag
    def->safe = *buf++;

    // Reads lengths
    def->rbag_len = *buf++;
    def->node_len = *buf++;
    def->vars_len = *buf++;

    // Reads root
    def->root = *buf++;

    // Reads rbag_buf
    memcpy(def->rbag_buf, buf, 8*def->rbag_len);  
    buf += def->rbag_len * 2;
    
    // Reads node_buf
    memcpy(def->node_buf, buf, 8*def->node_len);
    buf += def->node_len * 2;
  }
}

// Debug Printing
// --------------

__device__ __host__ void put_u32(char* B, u32 val) {
  for (int i = 0; i < 8; i++, val >>= 4) {
    B[8-i-1] = "0123456789ABCDEF"[val & 0xF];
  }
}

__device__ __host__ Show show_port(Port port) {
  // NOTE: this is done like that because sprintf seems not to be working
  Show s;
  switch (get_tag(port)) {
    case VAR: memcpy(s.x, "VAR:", 4); put_u32(s.x+4, get_val(port)); break;
    case REF: memcpy(s.x, "REF:", 4); put_u32(s.x+4, get_val(port)); break;
    case ERA: memcpy(s.x, "ERA:________", 12); break;
    case NUM: memcpy(s.x, "NUM:", 4); put_u32(s.x+4, get_val(port)); break;
    case CON: memcpy(s.x, "CON:", 4); put_u32(s.x+4, get_val(port)); break;
    case DUP: memcpy(s.x, "DUP:", 4); put_u32(s.x+4, get_val(port)); break;
    case OPR: memcpy(s.x, "OPR:", 4); put_u32(s.x+4, get_val(port)); break;
    case SWI: memcpy(s.x, "SWI:", 4); put_u32(s.x+4, get_val(port)); break;
  }
  s.x[12] = '\0';
  return s;
}

__device__ Show show_rule(Rule rule) {
  Show s;
  switch (rule) {
    case LINK: memcpy(s.x, "LINK", 4); break;
    case VOID: memcpy(s.x, "VOID", 4); break;
    case ERAS: memcpy(s.x, "ERAS", 4); break;
    case ANNI: memcpy(s.x, "ANNI", 4); break;
    case COMM: memcpy(s.x, "COMM", 4); break;
    case OPER: memcpy(s.x, "OPER", 4); break;
    case SWIT: memcpy(s.x, "SWIT", 4); break;
    case CALL: memcpy(s.x, "CALL", 4); break;
    default  : memcpy(s.x, "????", 4); break;
  }
  s.x[4] = '\0';
  return s;
}

__device__ void print_rbag(RBag* rbag) {
  printf("RBAG | FST-TREE     | SND-TREE    \n");
  printf("---- | ------------ | ------------\n");
  for (u32 i = rbag->lo_ini; i < rbag->lo_end; ++i) {
    Pair redex = rbag->lo_buf[i%RLEN];
    printf("%04X | %s | %s\n", i, show_port((Port)get_fst(redex)).x, show_port((Port)get_snd(redex)).x);
  }

  for (u32 i = 0; i > rbag->hi_end; ++i) {
    Pair redex = rbag->hi_buf[i];
    printf("%04X | %s | %s\n", i, show_port((Port)get_fst(redex)).x, show_port((Port)get_snd(redex)).x);
  }
  printf("==== | ============ | ============\n");
}

__device__ __host__ void print_net(Net* net) {
  printf("NODE | PORT-1       | PORT-2      \n");
  printf("---- | ------------ | ------------\n");
  for (u32 i = 0; i < G_NODE_LEN; ++i) {
    Pair node = node_load(net, i);
    if (node != 0) {
      printf("%04X | %s | %s\n", i, show_port(get_fst(node)).x, show_port(get_snd(node)).x);
    }
  }
  printf("==== | ============ |\n");
  printf("VARS | VALUE        |\n");
  printf("---- | ------------ |\n");
  for (u32 i = 0; i < G_VARS_LEN; ++i) {
    Port var = vars_load(net,i);
    if (var != 0) {
      printf("%04X | %s |\n", i, show_port(vars_load(net,i)).x);
    }
  }
  printf("==== | ============ |\n");
}

__device__ void pretty_print_port(Net* net, Port port) {
  Port stack[32];
  stack[0] = port;
  u32 len = 1;
  u32 num = 0;
  while (len > 0) {
    if (++num > 256) {
      printf("(...)\n");
      return;
    }
    if (len > 32) {
      printf("...");
      --len;
      continue;
    }
    Port cur = stack[--len];
    if (cur > 0xFFFFFF00) {
      printf("%c", (char)(cur&0xFF));
      continue;
    }
    switch (get_tag(cur)) {
      case CON: {
        Pair node = node_load(net,get_val(cur));
        Port p2   = get_snd(node);
        Port p1   = get_fst(node);
        printf("(");
        stack[len++] = (0xFFFFFF00) | (u32)(')');
        stack[len++] = p2;
        stack[len++] = (0xFFFFFF00) | (u32)(' ');
        stack[len++] = p1;
        break;
      }
      case ERA: {
        printf("*");
        break;
      }
      case VAR: {
        printf("x%x", get_val(cur));
        Port got = vars_load(net, get_val(cur));
        if (got != NONE) {
          printf("=");
          stack[len++] = got;
        }
        break;
      }
      case NUM: {
        Numb word = get_val(cur);
        switch (get_typ(word)) {
          case SYM: printf("[%x]", get_sym(word)); break;
          case U24: printf("%u", get_u24(word)); break;
          case I24: printf("%d", get_i24(word)); break;
          case F24: printf("%f", get_f24(word)); break;
        }
        break;
      }
      case DUP: {
        Pair node = node_load(net,get_val(cur));
        Port p2   = get_snd(node);
        Port p1   = get_fst(node);
        printf("{");
        stack[len++] = (0xFFFFFF00) | (u32)('}');
        stack[len++] = p2;
        stack[len++] = (0xFFFFFF00) | (u32)(' ');
        stack[len++] = p1;
        break;
      }
      case OPR: {
        Pair node = node_load(net,get_val(cur));
        Port p2   = get_snd(node);
        Port p1   = get_fst(node);
        printf("<+ ");
        stack[len++] = (0xFFFFFF00) | (u32)('>');
        stack[len++] = p2;
        stack[len++] = (0xFFFFFF00) | (u32)(' ');
        stack[len++] = p1;
        break;
      }
      case SWI: {
        Pair node = node_load(net,get_val(cur));
        Port p2   = get_snd(node);
        Port p1   = get_fst(node);
        printf("?<"); 
        stack[len++] = (0xFFFFFF00) | (u32)('>');
        stack[len++] = p2;
        stack[len++] = (0xFFFFFF00) | (u32)(' ');
        stack[len++] = p1;
        break;
      }
      case REF: {
        printf("@%d", get_val(cur));
        break;
      }
    }
  }
}

__device__ void pretty_print_rbag(Net* net, RBag* rbag) {
  for (u32 i = rbag->lo_ini; i < rbag->lo_end; ++i) {
    Pair redex = rbag->lo_buf[i%RLEN];
    if (redex != 0) {
      pretty_print_port(net, get_fst(redex)); 
      printf(" ~ ");
      pretty_print_port(net, get_snd(redex));
      printf("\n");
    }
  }
  for (u32 i = 0; i > rbag->hi_end; ++i) {
    Pair redex = rbag->hi_buf[i];
    if (redex != 0) {
      pretty_print_port(net, get_fst(redex));
      printf(" ~ ");
      pretty_print_port(net, get_snd(redex));
      printf("\n");
    }
  }
}

__global__ void print_rbag_heatmap(GNet* gnet, u32 turn) {
  if (GID() > 0) return;
  for (u32 bid = 0; bid < BPG; bid++) {
    for (u32 tid = 0; tid < TPB; tid++) {
      u32 gid = bid * TPB + tid;
      u32 len = 0;
      for (u32 i = 0; i < RLEN; i++) {
        if ( turn % 2 == 0 && gnet->rbag_buf_A[gid * RLEN + i] != 0
          || turn % 2 == 1 && gnet->rbag_buf_B[gid * RLEN + i] != 0) {
          len++;
        }
      }
      u32 heat = min(len, 0xF);
      printf("%x", heat);
    }
    printf("\n");
  }
}

__global__ void print_result(GNet* gnet, u32 turn) {
  Net net = vnet_new(gnet, NULL, turn);
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    printf("Result: ");
    pretty_print_port(&net, enter(&net, NULL, ROOT));
    printf("\n");
  }
}

// Main
// ----

// Stress 2^18 x 65536
static const u8 DEMO_BOOK[] = {6, 0, 0, 0, 0, 0, 0, 0, 109, 97, 105, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 4, 0, 0, 0, 11, 9, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 102, 117, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 25, 0, 0, 0, 2, 0, 0, 0, 102, 117, 110, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 4, 0, 0, 0, 11, 0, 128, 0, 0, 0, 0, 0, 3, 0, 0, 0, 102, 117, 110, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0, 20, 0, 0, 0, 9, 0, 0, 0, 36, 0, 0, 0, 13, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 24, 0, 0, 0, 16, 0, 0, 0, 8, 0, 0, 0, 24, 0, 0, 0, 4, 0, 0, 0, 108, 111, 112, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 0, 41, 0, 0, 0, 5, 0, 0, 0, 108, 111, 112, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 33, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0};

// Stress 2^14 x 65536
//static const u8 DEMO_BOOK[] = {6, 0, 0, 0, 0, 0, 0, 0, 109, 97, 105, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 4, 0, 0, 0, 11, 7, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 102, 117, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 25, 0, 0, 0, 2, 0, 0, 0, 102, 117, 110, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 4, 0, 0, 0, 11, 0, 128, 0, 0, 0, 0, 0, 3, 0, 0, 0, 102, 117, 110, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0, 20, 0, 0, 0, 9, 0, 0, 0, 36, 0, 0, 0, 13, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 24, 0, 0, 0, 16, 0, 0, 0, 8, 0, 0, 0, 24, 0, 0, 0, 4, 0, 0, 0, 108, 111, 112, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 0, 41, 0, 0, 0, 5, 0, 0, 0, 108, 111, 112, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 33, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0};

// Stress 2^18 x 16
//static const u8 DEMO_BOOK[] = {6, 0, 0, 0, 0, 0, 0, 0, 109, 97, 105, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 4, 0, 0, 0, 11, 9, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 102, 117, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 17, 0, 0, 0, 25, 0, 0, 0, 2, 0, 0, 0, 102, 117, 110, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 4, 0, 0, 0, 11, 8, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 102, 117, 110, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0, 20, 0, 0, 0, 9, 0, 0, 0, 36, 0, 0, 0, 13, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 24, 0, 0, 0, 16, 0, 0, 0, 8, 0, 0, 0, 24, 0, 0, 0, 4, 0, 0, 0, 108, 111, 112, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 0, 41, 0, 0, 0, 5, 0, 0, 0, 108, 111, 112, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 33, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0};

// Bug2
//static const u8 DEMO_BOOK[] = {8, 0, 0, 0, 0, 0, 0, 0, 109, 97, 105, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 49, 0, 0, 0, 4, 0, 0, 0, 25, 0, 0, 0, 12, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 11, 11, 0, 0, 20, 0, 0, 0, 11, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0, 76, 101, 97, 102, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 20, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0, 78, 111, 100, 101, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 8, 0, 0, 0, 20, 0, 0, 0, 2, 0, 0, 0, 28, 0, 0, 0, 36, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 44, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 103, 101, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 41, 0, 0, 0, 4, 0, 0, 0, 103, 101, 110, 36, 67, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 5, 0, 0, 0, 103, 101, 110, 36, 67, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 13, 0, 0, 0, 7, 0, 0, 0, 4, 0, 0, 0, 17, 0, 0, 0, 60, 0, 0, 0, 25, 0, 0, 0, 76, 0, 0, 0, 25, 0, 0, 0, 92, 0, 0, 0, 13, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0, 29, 0, 0, 0, 32, 0, 0, 0, 38, 0, 0, 0, 54, 0, 0, 0, 51, 1, 0, 0, 46, 0, 0, 0, 163, 0, 0, 0, 16, 0, 0, 0, 51, 1, 0, 0, 24, 0, 0, 0, 40, 0, 0, 0, 68, 0, 0, 0, 48, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 84, 0, 0, 0, 16, 0, 0, 0, 40, 0, 0, 0, 8, 0, 0, 0, 100, 0, 0, 0, 24, 0, 0, 0, 48, 0, 0, 0, 6, 0, 0, 0, 115, 117, 109, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 12, 0, 0, 0, 8, 0, 0, 0, 20, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 57, 0, 0, 0, 8, 0, 0, 0, 7, 0, 0, 0, 115, 117, 109, 36, 67, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 6, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 49, 0, 0, 0, 20, 0, 0, 0, 49, 0, 0, 0, 44, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 3, 2, 0, 128, 38, 0, 0, 0, 24, 0, 0, 0, 16, 0, 0, 0, 8, 0, 0, 0, 24, 0, 0, 0};

void hvm_cu(u32* book_buffer) {
  // Start the timer
  clock_t start = clock();
  
  // Loads the Book
  if (book_buffer) {
    Book* book = (Book*)malloc(sizeof(Book));
    book_load((u32*)book_buffer, book);
    cudaMemcpyToSymbol(BOOK, book, sizeof(Book));
    free(book);
  }

  // GMem
  GNet *d_gnet;
  cudaMalloc((void**)&d_gnet, sizeof(GNet));
  cudaMemset(d_gnet, 0, sizeof(GNet));

  // Set the initial redex
  Pair pair = new_pair(new_port(REF, 0), ROOT);
  cudaMemcpy(&d_gnet->rbag_buf_A[0], &pair, sizeof(Pair), cudaMemcpyHostToDevice);

  // Configures Shared Memory Size
  cudaFuncSetAttribute(evaluator, cudaFuncAttributeMaxDynamicSharedMemorySize, sizeof(LNet));

  // Inits the GNet
  gnet_init<<<div(G_PAGE_MAX,TPB), TPB>>>(d_gnet);

  // Invokes the Evaluator Kernel repeatedly
  u32 turn;
  for (turn = 0; turn < 0xFFFF; ++turn) {
    evaluator<<<BPG, TPB, sizeof(LNet)>>>(d_gnet, turn);
    swap_rbuf<<<1, 1>>>(d_gnet, turn);
    if (get_rbag_len(d_gnet, turn) == 0) {
      printf("Completed after %d kernel launches!\n", turn);
      break;
    }
    // Print HeatMap (for debugging)
    //cudaDeviceSynchronize();
    //print_rbag_heatmap<<<1,1>>>(d_gnet, turn+1);
    //cudaDeviceSynchronize();
    //printf("-------------------------------------------- %04x\n", turn);
  }

  // Invokes the Result Printer Kernel
  cudaDeviceSynchronize();
  print_result<<<1,1>>>(d_gnet, turn);

  // Reports errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    fprintf(stderr, "Failed to launch kernels (error code %s)!\n", cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }

  // Stops the timer
  clock_t end = clock();
  double duration = ((double)(end - start)) / CLOCKS_PER_SEC;

  //{
    //// Allocate host memory for the net
    //GNet *h_gnet = (GNet*)malloc(sizeof(GNet));

    //// Copy the net from device to host 
    //cudaMemcpy(h_gnet, d_gnet, sizeof(GNet), cudaMemcpyDeviceToHost);

    //// Create a Net view of the host GNet
    //Net net;
    //net.g_node_buf = h_gnet->node_buf; 
    //net.g_vars_buf = h_gnet->vars_buf;
    //net.g_page_idx = 0xFFFFFFFF;

    //// Print the net
    //print_net(&net);

    //// Free host memory  
    //free(h_gnet);
  //}

  // Gets interaction count
  u64 itrs;
  cudaMemcpy(&itrs, &d_gnet->itrs, sizeof(u64), cudaMemcpyDeviceToHost);

  // Prints interactions, time and MIPS
  printf("- ITRS: %llu\n", itrs);
  printf("- TIME: %.2fs\n", duration);  
  printf("- MIPS: %.2f\n", (double)itrs / duration / 1000000.0);
}

int main() {
  hvm_cu((u32*)DEMO_BOOK);
  //hvm_cu(NULL);
  return 0;
}
