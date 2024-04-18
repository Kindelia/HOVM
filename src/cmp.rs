use crate::ast;
use crate::hvm;

use std::collections::HashMap;

// Compiles a whole Book.
pub fn compile_book(book: &hvm::Book) -> String {
  let mut code = String::new();
  code.push_str(&format!("bool interact_call_native(GNet *net, TMem *tm, Port a, Port b) {{\n"));
  code.push_str(&format!("  u32 fid = get_val(a);\n"));
  code.push_str(&format!("  switch (fid) {{\n"));
  for (fid, def) in book.defs.iter().enumerate() {
    code.push_str(&format!("    case {}: return interact_call_{}(net, tm, a, b);\n", fid, &def.name));
  }
  code.push_str(&format!("    default: return false;\n"));
  code.push_str(&format!("  }}\n"));
  code.push_str(&format!("}}\n\n"));
  for fid in 0..book.defs.len() {
    compile_def(&mut code, book, 0, fid as hvm::Val);
    code.push_str(&format!("\n"));
  }
  return code;
}

// Compiles a single Def.
pub fn compile_def(code: &mut String, book: &hvm::Book, tab: usize, fid: hvm::Val) {
  let def = &book.defs[fid as usize];
  let fun = &def.name;

  // Initializes context
  let neo = &mut 0;
  
  // Generates function
  code.push_str(&format!("{}bool interact_call_{}(GNet *net, TMem *tm, Port a, Port b) {{\n", indent(tab), fun));

  // Allocs resources (using fast allocator)
  for i in 0 .. def.vars {
    code.push_str(&format!("{}Val v{:x} = vars_alloc_1(net, tm);\n", indent(tab+1), i));
  }
  for i in 0 .. def.node.len()-1 {
    code.push_str(&format!("{}Val n{:x} = node_alloc_1(net, tm);\n", indent(tab+1), i));
  }
  code.push_str(&format!("{}if (0", indent(tab+1)));
  for i in 0 .. def.vars {
    code.push_str(&format!(" || !v{:x}", i));
  }
  for i in 0 .. def.node.len()-1 {
    code.push_str(&format!(" || !n{:x}", i));
  }
  code.push_str(&format!(") {{\n"));
  code.push_str(&format!("{}return false;\n", indent(tab+2)));
  code.push_str(&format!("{}}}\n", indent(tab+1)));
  for i in 0 .. def.vars {
    code.push_str(&format!("{}vars_create(net, v{:x}, NONE);\n", indent(tab+1), i));
  }

  // Allocs resources (using slow allocator)
  //code.push_str(&format!("{}// Allocates needed resources.\n", indent(tab+1)));
  //code.push_str(&format!("{}if (!get_resources(net, tm, {}, {}, {})) {{\n", indent(tab+1), def.rbag.len()+1, def.node.len()-1, def.vars));
  //code.push_str(&format!("{}return false;\n", indent(tab+2)));
  //code.push_str(&format!("{}}}\n", indent(tab+1)));
  //for i in 0 .. def.node.len()-1 {
    //code.push_str(&format!("{}Val n{:x} = tm->node_loc[0x{:x}];\n", indent(tab+1), i, i));
  //}
  //for i in 0 .. def.vars {
    //code.push_str(&format!("{}Val v{:x} = tm->vars_loc[0x{:x}];\n", indent(tab+1), i, i));
  //}
  //for i in 0 .. def.vars {
    //code.push_str(&format!("{}vars_create(net, v{:x}, NONE);\n", indent(tab+1), i));
  //}

  // Compiles rbag
  for redex in &def.rbag {
    let fun = compile_atom(redex.get_fst());
    let arg = compile_node(code, book, neo, tab+1, def, redex.get_snd());
    code.push_str(&format!("{}link(net, tm, {}, {});\n", indent(tab+1), &fun, &arg));
  }

  // Compiles root
  compile_link_fast(code, book, neo, tab+1, def, def.node[0].get_fst(), "b");

  // Return
  code.push_str(&format!("{}return true;\n", indent(tab+1)));
  code.push_str(&format!("{}}}\n", indent(tab)));
}

// Compiles a link, performing some pre-defined static reductions.
pub fn compile_link_fast(code: &mut String, book: &hvm::Book, neo: &mut usize, tab: usize, def: &hvm::Def, a: hvm::Port, b: &str) {
  // (<?(a111 a112) a12> a2) <~ (#X R)
  // --------------------------------- fast SWITCH
  // if X == 0:
  //   a111 <~ R
  //   a112 <~ ERAS
  // else:
  //   a111 <~ ERAS
  //   a112 <~ (#(X-1) R)
  if a.get_tag() == hvm::CON {
    let a_ = &def.node[a.get_val() as usize];
    let a1 = a_.get_fst();
    let a2 = a_.get_snd();
    if a1.get_tag() == hvm::SWI {
      let a1_ = &def.node[a1.get_val() as usize];
      let a11 = a1_.get_fst();
      let a12 = a1_.get_snd();
      if a11.get_tag() == hvm::CON && a2.get_tag() == hvm::VAR && a12.0 == a2.0 {
        let a11_ = &def.node[a11.get_val() as usize];
        let a111 = a11_.get_fst();
        let a112 = a11_.get_snd();
        let op   = fresh(neo);
        let bv   = fresh(neo);
        let x1   = fresh(neo);
        let x2   = fresh(neo);
        let nu   = fresh(neo);
        code.push_str(&format!("{}bool {} = 0;\n", indent(tab), &op));
        code.push_str(&format!("{}Pair {} = 0;\n", indent(tab), &bv));
        code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &nu));
        code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x1));
        code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x2));
        code.push_str(&format!("{}//fast switch\n", indent(tab)));
        code.push_str(&format!("{}if (get_tag({}) == CON) {{\n", indent(tab), b));
        code.push_str(&format!("{}{} = node_load(net, get_val({}));\n", indent(tab+1), &bv, b)); // recycled
        code.push_str(&format!("{}{} = enter(net,tm,get_fst({}));\n", indent(tab+1), &nu, &bv));
        code.push_str(&format!("{}if (get_tag({}) == NUM) {{\n", indent(tab+1), &nu));
        code.push_str(&format!("{}tm->itrs += 3;\n", indent(tab+2)));
        code.push_str(&format!("{}{} = 1;\n", indent(tab+2), &op));
        code.push_str(&format!("{}if (get_val({}) == 0) {{\n", indent(tab+2), &nu));
        code.push_str(&format!("{}node_take(net, get_val({}));\n", indent(tab+3), b));
        code.push_str(&format!("{}{} = get_snd({});\n", indent(tab+3), &x1, &bv));
        code.push_str(&format!("{}{} = new_port(ERA,0);\n", indent(tab+3), &x2));
        code.push_str(&format!("{}}} else {{\n", indent(tab+2)));
        code.push_str(&format!("{}node_store(net, get_val({}), new_pair(new_port(NUM,get_val({})-1), get_snd({})));\n", indent(tab+3), b, &nu, &bv));
        code.push_str(&format!("{}{} = new_port(ERA,0);\n", indent(tab+3), &x1));
        code.push_str(&format!("{}{} = {};\n", indent(tab+3), &x2, b));
        code.push_str(&format!("{}}}\n", indent(tab+2)));
        code.push_str(&format!("{}}} else {{\n", indent(tab+1)));
        code.push_str(&format!("{}node_store(net, get_val({}), new_pair({},get_snd({})));\n", indent(tab+2), b, &nu, &bv)); // update "entered" var
        code.push_str(&format!("{}}}\n", indent(tab+1)));
        code.push_str(&format!("{}}}\n", indent(tab+0)));
        compile_link_fast(code, book, neo, tab, def, a111, &x1);
        compile_link_fast(code, book, neo, tab, def, a112, &x2);
        code.push_str(&format!("{}if (!{}) {{\n", indent(tab), &op));
        code.push_str(&format!("{}node_create(net, n{:x}, new_pair(new_port(SWI,n{}),new_port(VAR,v{})));\n", indent(tab+1), a.get_val()-1, a1.get_val()-1, a2.get_val()));
        code.push_str(&format!("{}node_create(net, n{:x}, new_pair(new_port(CON,n{}),new_port(VAR,v{})));\n", indent(tab+1), a1.get_val()-1, a11.get_val()-1, a12.get_val()));
        code.push_str(&format!("{}node_create(net, n{:x}, new_pair({},{}));\n", indent(tab+1), a11.get_val()-1, &x1, &x2));
        code.push_str(&format!("{}link(net, tm, new_port(CON, n{:x}), {});\n", indent(tab+1), a.get_val()-1, b));
        code.push_str(&format!("{}}}\n", indent(tab)));
        return;
      }
    }
  }

  // FIXME: REVIEW
  // <+ #B r> <~ #A
  // --------------- fast OPER
  // r <~ #(op(A,B))
  if a.get_tag() == hvm::OPR {
    let a_ = &def.node[a.get_val() as usize];
    let a1 = a_.get_fst();
    let a2 = a_.get_snd();
    let op = fresh(neo);
    let x1 = compile_node(code, book, neo, tab, def, a1);
    let x2 = fresh(neo);
    code.push_str(&format!("{}bool {} = 0;\n", indent(tab), &op));
    code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x2));
    code.push_str(&format!("{}// fast oper\n", indent(tab)));
    code.push_str(&format!("{}if (get_tag({}) == NUM && get_tag({}) == NUM) {{\n", indent(tab), b, &x1));
    code.push_str(&format!("{}tm->itrs += 2;\n", indent(tab+1)));
    code.push_str(&format!("{}{} = 1;\n", indent(tab+1), &op));
    code.push_str(&format!("{}{} = new_port(NUM, get_val({}) + get_val({}));\n", indent(tab+1), &x2, b, &x1));
    code.push_str(&format!("{}}}\n", indent(tab)));
    compile_link_fast(code, book, neo, tab, def, a2, &x2);
    code.push_str(&format!("{}if (!{}) {{\n", indent(tab), &op));
    code.push_str(&format!("{}node_create(net, n{:x}, new_pair({},{}));\n", indent(tab+1), a.get_val()-1, &x1, &x2));
    code.push_str(&format!("{}link(net, tm, new_port(OPR, n{:x}), {});\n", indent(tab+1), a.get_val()-1, b));
    code.push_str(&format!("{}}}\n", indent(tab)));
    return;
  }

  // FIXME: REVIEW
  // {a1 a2} <~ #v
  // ------------- Fast COPY
  // a1 <~ #v
  // a2 <~ #v
  if a.get_tag() == hvm::DUP {
    let a_ = &def.node[a.get_val() as usize];
    let p1 = a_.get_fst();
    let p2 = a_.get_snd();
    let op = fresh(neo);
    let x1 = fresh(neo);
    let x2 = fresh(neo);
    code.push_str(&format!("{}bool {} = 0;\n", indent(tab), &op));
    code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x1));
    code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x2));
    code.push_str(&format!("{}// fast copy\n", indent(tab)));
    code.push_str(&format!("{}if (get_tag({}) == NUM) {{\n", indent(tab), b));
    code.push_str(&format!("{}tm->itrs += 1;\n", indent(tab+1)));
    code.push_str(&format!("{}{} = 1;\n", indent(tab+1), &op));
    code.push_str(&format!("{}{} = {};\n", indent(tab+1), &x1, b));
    code.push_str(&format!("{}{} = {};\n", indent(tab+1), &x2, b));
    code.push_str(&format!("{}}}\n", indent(tab)));
    compile_link_fast(code, book, neo, tab, def, p2, &x2);
    compile_link_fast(code, book, neo, tab, def, p1, &x1);
    code.push_str(&format!("{}if (!{}) {{\n", indent(tab), &op));
    code.push_str(&format!("{}node_create(net, n{:x}, new_pair({},{}));\n", indent(tab+1), a.get_val()-1, x1, x2));
    code.push_str(&format!("{}link(net, tm, new_port(DUP,n{:x}), {});\n", indent(tab+1), a.get_val()-1, b));
    code.push_str(&format!("{}}}\n", indent(tab)));
    return;
  }

  // (a1 a2) <~ (x1 x2)
  // ------------------ Fast ANNI
  // a1 <~ x1
  // a2 <~ x2
  if a.get_tag() == hvm::CON {
    let a_ = &def.node[a.get_val() as usize];
    let a1 = a_.get_fst();
    let a2 = a_.get_snd();
    let bv = fresh(neo);
    let x1 = fresh(neo);
    let x2 = fresh(neo);
    code.push_str(&format!("{}Pair {} = 0;\n", indent(tab), &bv));
    code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x1));
    code.push_str(&format!("{}Port {} = 0;\n", indent(tab), &x2));
    code.push_str(&format!("{}// fast anni\n", indent(tab)));
    code.push_str(&format!("{}if (get_tag({}) == CON && node_load(net, get_val({})) != 0) {{\n", indent(tab), b, b));
    code.push_str(&format!("{}tm->itrs += 1;\n", indent(tab+1)));
    code.push_str(&format!("{}{} = node_take(net, get_val({}));\n", indent(tab+1), &bv, b));
    code.push_str(&format!("{}{} = get_fst({});\n", indent(tab+1), x1, &bv));
    code.push_str(&format!("{}{} = get_snd({});\n", indent(tab+1), x2, &bv));
    code.push_str(&format!("{}}}\n", indent(tab)));
    compile_link_fast(code, book, neo, tab, def, a2, &x2);
    compile_link_fast(code, book, neo, tab, def, a1, &x1);
    code.push_str(&format!("{}if (!{}) {{\n", indent(tab), &bv));
    code.push_str(&format!("{}node_create(net, n{:x}, new_pair({},{}));\n", indent(tab+1), a.get_val()-1, x1, x2));
    code.push_str(&format!("{}link(net, tm, new_port(CON,n{:x}), {});\n", indent(tab+1), a.get_val()-1, b));
    code.push_str(&format!("{}}}\n", indent(tab)));
    return;
  }

  // ATOM <~ *
  // --------- Fast VOID
  // nothing
  if a.get_tag() == hvm::NUM || a.get_tag() == hvm::ERA || a.get_tag() == hvm::REF {
    code.push_str(&format!("{}// fast void\n", indent(tab)));
    code.push_str(&format!("{}if (get_tag({}) == ERA || get_tag({}) == NUM || get_tag({}) == REF) {{\n", indent(tab), b, b, b));
    code.push_str(&format!("{}tm->itrs += 1;\n", indent(tab+1)));
    code.push_str(&format!("{}}} else {{\n", indent(tab)));
    compile_link_slow(code, book, neo, tab+1, def, a, b);
    code.push_str(&format!("{}}}\n", indent(tab)));
    return;
  }

  compile_link_slow(code, book, neo, tab, def, a, b);
}

// Compiles a link, without pre-defined reductions.
pub fn compile_link_slow(code: &mut String, book: &hvm::Book, neo: &mut usize, tab: usize, def: &hvm::Def, a: hvm::Port, b: &str) {
  let a_node = compile_node(code, book, neo, tab, def, a);
  code.push_str(&format!("{}if ({}) {{\n", indent(tab), b));
  code.push_str(&format!("{}link(net, tm, {}, {});\n", indent(tab+1), b, a_node));  
  code.push_str(&format!("{}}} else {{\n", indent(tab)));
  code.push_str(&format!("{}{} = {};\n", indent(tab+1), b, a_node));
  code.push_str(&format!("{}}}\n", indent(tab)));
}

// Compiles just a node.
pub fn compile_node(code: &mut String, book: &hvm::Book, neo: &mut usize, tab: usize, def: &hvm::Def, a: hvm::Port) -> String {
  if a.is_nod() {
    let nd = &def.node[a.get_val() as usize];
    let p1 = compile_node(code, book, neo, tab, def, nd.get_fst());
    let p2 = compile_node(code, book, neo, tab, def, nd.get_snd());
    code.push_str(&format!("{}node_create(net, n{:x}, new_pair({},{}));\n", indent(tab), a.get_val()-1, p1, p2));
    return format!("new_port({},n{:x})", compile_tag(a.get_tag()), a.get_val()-1);
  } else if a.is_var() {
    return format!("new_port(VAR,v{:x})", a.get_val());
  } else {
    return format!("new_port({},0x{:08x})", compile_tag(a.get_tag()), a.get_val());
  }
}

// Compiles an atomic port.
fn compile_atom(port: hvm::Port) -> String {
  return format!("new_port({},0x{:08x})", compile_tag(port.get_tag()), port.get_val());
}

// Compiles a tag.
pub fn compile_tag(tag: hvm::Tag) -> &'static str {
  match tag {
    hvm::VAR => "VAR",
    hvm::REF => "REF",
    hvm::ERA => "ERA",
    hvm::NUM => "NUM",
    hvm::OPR => "OPR",
    hvm::SWI => "SWI",
    hvm::CON => "CON",
    hvm::DUP => "DUP",
    _ => unreachable!(),
  }
}

// Creates indentation.
pub fn indent(tab: usize) -> String {
  return "  ".repeat(tab);
}

// Generates a fresh name.
fn fresh(count: &mut usize) -> String {
  *count += 1;
  format!("k{}", count)
}
