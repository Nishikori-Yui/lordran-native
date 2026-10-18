#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }   // shader keys from hle_nvn.c: this test does not link it, so a zero key (the missing stub broke the link)
uint64_t nvn_new_serial(void) { static uint64_t serial; return ++serial; }
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static int cases,bad;
static int ro(NSDictionary *j){
#ifdef NVN_RT_RANGE_RO_IMPL
 return rt_range_bindings_ro(j);
#else
 return 0;
#endif
}
#define E(n,w,a) do{int v=(a);cases++;printf("%s 期望%d → 真结果%d\n",n,w,v);bad+=(w)!=v;}while(0)
static NSDictionary *one(NSDictionary *b){return @{ @"route":@"B",@"drv_reads":@{},@"bindings":@[b] };}
int main(void){@autoreleasepool{
 E("明确sbuf RO",1,ro(one(@{@"kind":@"sbuf",@"msl_type":@"const device _27*",@"rw":@NO})));
 E("缺rw不当默认0证明",0,ro(one(@{@"kind":@"sbuf",@"msl_type":@"const device _27*"})));
 E("rw写用途拒绝",0,ro(one(@{@"kind":@"sbuf",@"msl_type":@"device _27*",@"rw":@YES})));
 E("device缺const拒绝",0,ro(one(@{@"kind":@"sbuf",@"msl_type":@"device _27*",@"rw":@NO})));
 E("image未知用途拒绝",0,ro(one(@{@"kind":@"img",@"msl_type":@"texture2d<float, access::read>"})));
 E("sample纹理明确RO",1,ro(one(@{@"kind":@"tex",@"msl_type":@"texture2d<float>"})));
 E("tex显式rw拒绝",0,ro(one(@{@"kind":@"tex",@"msl_type":@"texture2d<float>",@"rw":@YES})));
 E("constant cbuf显式rw拒绝",0,ro(one(@{@"kind":@"cbuf",@"msl_type":@"constant _16*",@"rw":@YES})));
 E("rw类型未知拒绝",0,ro(one(@{@"kind":@"tex",@"msl_type":@"texture2d<float>",@"rw":@"false"})));
 E("driver间接地址不扩展",0,ro(one(@{@"kind":@"drv0",@"msl_type":@"constant _16*"})));
 E("texture read_write拒绝",0,ro(one(@{@"kind":@"tex",@"msl_type":@"texture2d<float, access::read_write>"})));
 E("texture write拒绝",0,ro(one(@{@"kind":@"tex",@"msl_type":@"texture2d<float, access::write>"})));
 E("cbuf constant明确RO",1,ro(one(@{@"kind":@"cbuf",@"msl_type":@"constant _16*"})));
 E("cbuf类型未知拒绝",0,ro(one(@{@"kind":@"cbuf",@"msl_type":@"device _16*"})));
 E("未知kind拒绝",0,ro(one(@{@"kind":@"opaque",@"msl_type":@"constant _16*"})));
 E("缺bindings拒绝",0,ro(@{@"route":@"B"}));
 E("缺driver语义信息拒绝",0,ro(@{@"route":@"B",@"bindings":@[]}));
 E("存在driver间接读取拒绝",0,ro(@{@"route":@"B",@"bindings":@[],@"drv_reads":@{@"0":@YES}}));
 NSDictionary *valid = @{@"route": @"B", @"drv_reads": @{}, @"bindings": @[
     @{@"kind": @"cbuf", @"msl_type": @"constant _16*"},
     @{@"kind": @"c1", @"msl_type": @"constant _16*"},
     @{@"kind": @"sbuf", @"msl_type": @"const device _27*", @"rw": @NO},
     @{@"kind": @"samp", @"msl_type": @"sampler"},
     @{@"kind": @"tex", @"msl_type": @"texture2d<float>"},
     @{@"kind": @"tbuf", @"msl_type": @"texture_buffer<float>"}]};
 E("self-contained valid route-B fixture",1,ro(valid));
 printf("RT_RANGE_RO cases=%d failed=%d\n",cases,bad);return bad!=0;}}
