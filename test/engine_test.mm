// Standalone engine verification: same tokenizer + ignore-rule + Hunspell logic
// as the plugin, run against the installed en_US dictionary. Proves the heart
// works independent of the editor/UI (which sits on an off-screen Space here).
#import <Foundation/Foundation.h>
#include <hunspell/hunspell.hxx>
#include <iconv.h>
#include <string>
#include <vector>
#include <cstdio>

static uint32_t utf8Decode(const std::string &s, size_t i, int &len) {
    unsigned char c=(unsigned char)s[i];
    if(c<0x80){len=1;return c;}
    if((c>>5)==0x6&&i+1<s.size()){len=2;return((c&0x1F)<<6)|(s[i+1]&0x3F);}
    if((c>>4)==0xE&&i+2<s.size()){len=3;return((c&0x0F)<<12)|((s[i+1]&0x3F)<<6)|(s[i+2]&0x3F);}
    if((c>>3)==0x1E&&i+3<s.size()){len=4;return((c&0x07)<<18)|((s[i+1]&0x3F)<<12)|((s[i+2]&0x3F)<<6)|(s[i+3]&0x3F);}
    len=1;return c;
}
static bool cpIsLetter(uint32_t cp){ if(cp<0x80) return (cp>='A'&&cp<='Z')||(cp>='a'&&cp<='z'); static NSCharacterSet*L=[NSCharacterSet letterCharacterSet]; return cp<=0xFFFF?[L characterIsMember:(unichar)cp]:[L longCharacterIsMember:cp]; }
static bool cpIsDigit(uint32_t cp){return cp>='0'&&cp<='9';}
static bool cpIsUpper(uint32_t cp){ if(cp<0x80) return cp>='A'&&cp<='Z'; static NSCharacterSet*U=[NSCharacterSet uppercaseLetterCharacterSet]; return cp<=0xFFFF?[U characterIsMember:(unichar)cp]:[U longCharacterIsMember:cp]; }
static bool cpIsApostrophe(uint32_t cp){return cp=='\''||cp==0x2019;}

struct Tok{size_t s,e;std::string t;};
static std::vector<Tok> tokenize(const std::string&s){
    std::vector<Tok> out; size_t i=0,n=s.size();
    while(i<n){ int len; uint32_t cp=utf8Decode(s,i,len);
        if(cpIsLetter(cp)||cpIsDigit(cp)){ size_t start=i;
            while(i<n){ int l2; uint32_t c2=utf8Decode(s,i,l2);
                if(cpIsLetter(c2)||cpIsDigit(c2)){i+=l2;continue;}
                if(cpIsApostrophe(c2)){size_t j=i+l2; if(j<n){int l3;uint32_t c3=utf8Decode(s,j,l3); if(cpIsLetter(c3)){i=j;continue;}}}
                break; }
            out.push_back({start,i,s.substr(start,i-start)}); }
        else i+=len; }
    return out;
}
static std::string trimApos(std::string r){ while(!r.empty()&&r.front()=='\'')r.erase(r.begin()); while(!r.empty()&&r.back()=='\'')r.pop_back(); return r; }
// default ignore rules: digit, internal-capital
static bool shouldCheck(const std::string&w){
    if(w.empty())return false;
    std::vector<uint32_t> cps; for(size_t i=0;i<w.size();){int l;cps.push_back(utf8Decode(w,i,l));i+=l;}
    bool anyDigit=false,anyLetter=false,internalUpper=false;
    for(size_t k=0;k<cps.size();++k){uint32_t cp=cps[k]; if(cpIsDigit(cp))anyDigit=true; if(cpIsLetter(cp)){anyLetter=true; if(k>0&&cpIsUpper(cp))internalUpper=true;}}
    if(!anyLetter)return false;
    if(anyDigit)return false;        // ignore_containing_digit (default on)
    if(internalUpper)return false;   // ignore_having_a_capital (default on)
    return true;
}
static std::string conv(const std::string&in,const char*from,const char*to){
    if(std::string(from)==to)return in; iconv_t cd=iconv_open(to,from); if(cd==(iconv_t)-1)return in;
    std::vector<char> out((in.size()+1)*6+16); const char*ib=in.data(); size_t il=in.size(); char*ob=out.data(); size_t ol=out.size();
    size_t r=iconv(cd,(char**)&ib,&il,&ob,&ol); iconv_close(cd); if(r==(size_t)-1)return in; return std::string(out.data(),out.size()-ol);
}

int main(int argc,char**argv){
  @autoreleasepool{
    std::string dir = std::string(getenv("HOME"))+"/.nextpad++/plugins/Config/Hunspell";
    std::string aff=dir+"/en_US.aff", dic=dir+"/en_US.dic";
    Hunspell hs(aff.c_str(),dic.c_str());
    const char*enc=hs.get_dic_encoding(); std::string encoding=enc?enc:"UTF-8";
    printf("dict encoding: %s\n", encoding.c_str());
    NSString*content=[NSString stringWithContentsOfFile:@"/tmp/spell.txt" encoding:NSUTF8StringEncoding error:nil];
    std::string text = content?content.UTF8String:"";
    printf("=== misspellings ===\n");
    int count=0;
    for(auto&tk:tokenize(text)){
        std::string w=trimApos(tk.t);
        if(!shouldCheck(w)){printf("  skip   '%s'\n",w.c_str());continue;}
        std::string we=conv(w,"UTF-8",encoding.c_str());
        bool ok=hs.spell(we);
        printf("  %-6s '%s'\n", ok?"OK":"BAD", w.c_str());
        if(!ok){count++;
            if(count==1){ auto sg=hs.suggest(we); printf("    suggestions:"); for(size_t i=0;i<sg.size()&&i<5;++i){std::string s=conv(sg[i],encoding.c_str(),"UTF-8");printf(" %s",s.c_str());} printf("\n"); }
        }
    }
    printf("=== total misspelled: %d ===\n",count);
  }
  return 0;
}
