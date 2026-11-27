/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "sm8850_thermal_source.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MANIFEST "/data/adb/oneios-m3q-framework/thermal.guard.manifest"
#define BOOT_ID "/proc/sys/kernel/random/boot_id"
#define MAX_TEXT 8192u

static int fail(void) { errno = EINVAL; return -1; }
static int now_ms(uint64_t *v)
{
    struct timespec t;
    if (clock_gettime(CLOCK_BOOTTIME, &t) || t.tv_sec < 0) return -1;
    *v = (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
    return 0;
}
static int text(const struct oneios_raw_source *s, const char *relative,
                char *out, size_t cap, bool manifest)
{
    char path[1024];
#ifdef ONEIOS_RAW_SOURCE_TEST
    int len = snprintf(path, sizeof path, "%s%s", s->fixture, relative);
#else
    (void)s;
    int len = snprintf(path, sizeof path, "%s", relative);
#endif
    if (len < 0 || (size_t)len >= sizeof path) return fail();
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    int rc = -1;
    if (manifest) {
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) ||
            st.st_uid != geteuid() || (st.st_mode & 0777) != 0600)
            goto done;
    }
    size_t n = 0;
    while (n < cap - 1) {
        ssize_t got = read(fd, out+n, cap-1-n);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) goto done;
        if (!got) {
            if (!n || memchr(out, 0, n)) goto done;
            out[n] = 0; rc = 0; break;
        }
        n += (size_t)got;
    }
done:
    close(fd);
    return rc;
}
static int value(const struct oneios_raw_source *s, const char *p,
                 char *out, size_t cap)
{
    if (text(s, p, out, cap, false)) return -1;
    size_t n = strlen(out);
    if (out[n-1] == '\n') out[--n] = 0;
    if (!n || strchr(out, '\n') || strchr(out, '\r')) return fail();
    return 0;
}
static int number(const char *s, unsigned max, unsigned *out)
{
    if (!*s || strspn(s, "0123456789") != strlen(s)) return fail();
    unsigned n = 0;
    for (; *s; s++) {
        unsigned d = (unsigned)(*s-'0');
        if (d > max || n > (max-d)/10) return fail();
        n = n*10+d;
    }
    *out = n;
    return 0;
}
static int read_number(const struct oneios_raw_source *s, const char *p,
                       unsigned max, int *out)
{
    char b[64]; unsigned n;
    if (value(s,p,b,sizeof b) || number(b,max,&n) || !n) return fail();
    *out = (int)n; return 0;
}
static bool boot_matches(const struct oneios_raw_source *s)
{
    char boot[64];
    return !value(s, BOOT_ID, boot, sizeof boot) && !strcmp(boot,s->id.boot);
}
static bool identity_ok(const struct oneios_thermal_identity *id)
{
    if (!id || !memchr(id->boot,0,sizeof id->boot) ||
        !memchr(id->token,0,sizeof id->token) ||
        !memchr(id->generation,0,sizeof id->generation) ||
        strlen(id->boot)!=36 || strlen(id->token)!=32 ||
        strspn(id->token,"0123456789abcdef")!=32 ||
        !id->generation[0] ||
        strspn(id->generation,"0123456789abcdef.-")!=strlen(id->generation))
        return false;
    for (unsigned i=0;i<36;i++) {
        bool hyphen=i==8||i==13||i==18||i==23;
        if (hyphen ? id->boot[i]!='-' :
            !strchr("0123456789abcdef",id->boot[i])) return false;
    }
    return true;
}
static int group_for(const char *type, const char *group)
{
    if (!*type || strspn(type,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") != strlen(type))
        return -1;
    if (!strncmp(type,"cpu-hw-trip-",12)) return -1;
    if ((!strncmp(type,"cpu-",4)||!strncmp(type,"cpuss-",6)) && !strcmp(group,"cpu")) return 0;
    if (!strncmp(type,"gpuss-",6) && !strcmp(group,"gpu")) return 1;
    if (!strcmp(type,"ddr") && !strcmp(group,"ddr")) return 2;
    if (!strcmp(type,"xo-therm") && !strcmp(group,"xo")) return 3;
    return -1;
}
/* Strict line/token parser: exact field counts, no blank/overlong rows,
 * duplicate numeric zone indices or unknown group/type. */
static int fields(char *line, char **out, unsigned count)
{
    for (unsigned i=0;i<count;i++) {
        if (!*line || *line==' ') return fail();
        out[i]=line;
        char *next=strchr(line,' ');
        if (i+1==count) return next ? fail() : 0;
        if (!next) return fail();
        *next=0; line=next+1;
    }
    return fail();
}
static int load(struct oneios_raw_source *s,const struct oneios_thermal_identity *id)
{
    if (!identity_ok(id)) return fail();
    s->id=*id;
    char buf[MAX_TEXT], *f[4];
    if (!boot_matches(s) || text(s,MANIFEST,buf,sizeof buf,true)) return fail();
    char *line=buf, *nl=strchr(line,'\n');
    unsigned expected, groups[4]={0};
    bool seen[256]={false};
    if (!nl) return fail();
    *nl=0;
    if (fields(line,f,3) || strcmp(f[0],"v1") || strcmp(f[1],id->boot) ||
        number(f[2],ONEIOS_RAW_MAX_ZONES,&expected) || expected<3) return fail();
    line=nl+1;
    while (*line) {
        nl=strchr(line,'\n');
        if (!nl || s->count>=expected) return fail();
        *nl=0;
        unsigned idx;
        if (fields(line,f,4) || strcmp(f[0],"z") ||
            number(f[1],255,&idx) || seen[idx] || strlen(f[2])>=sizeof s->zones[0].type)
            return fail();
        int g=group_for(f[2],f[3]);
        if (g<0) return fail();
        seen[idx]=true; groups[g]++;
        struct oneios_raw_zone *z=&s->zones[s->count++];
        z->index=idx; z->group=(unsigned)g;
        strcpy(z->type,f[2]);
        line=nl+1;
    }
    if (s->count!=expected || !groups[0] || !groups[1] || !groups[2] ||
        !boot_matches(s)) return fail();
    s->ready=true;
    return 0;
}
int oneios_raw_source_open(struct oneios_raw_source *s,const struct oneios_thermal_identity *id)
{
    if (!s) return fail();
    memset(s,0,sizeof *s);
#ifdef ONEIOS_RAW_SOURCE_TEST
    /* The fixture build cannot open live paths. */
    (void)id; return fail();
#else
    if (geteuid()!=0) return fail();
    return load(s,id);
#endif
}
#ifdef ONEIOS_RAW_SOURCE_TEST
int oneios_raw_source_fixture(struct oneios_raw_source *s,
    const struct oneios_thermal_identity *id,const char *directory)
{
    if (!s || !directory || directory[0]!='/' || !directory[1] ||
        strlen(directory)>=sizeof s->fixture) return fail();
    memset(s,0,sizeof *s);
    strcpy(s->fixture,directory);
    return load(s,id);
}
#endif
int oneios_raw_source_read(struct oneios_raw_source *s,struct oneios_thermal_sample *out)
{
    uint64_t began, ended;
    if (!s || !s->ready || !out || s->seq==UINT64_MAX ||
        now_ms(&began) || began<s->last_ms || !boot_matches(s)) return fail();
    int max[4]={0};
    for (unsigned i=0;i<s->count;i++) {
        const struct oneios_raw_zone *z=&s->zones[i];
        char type[128], typepath[128], temppath[128];
        snprintf(typepath,sizeof typepath,"/sys/class/thermal/thermal_zone%u/type",z->index);
        snprintf(temppath,sizeof temppath,"/sys/class/thermal/thermal_zone%u/temp",z->index);
        int temp;
        if (value(s,typepath,type,sizeof type) || strcmp(type,z->type) ||
            read_number(s,temppath,200000,&temp) ||
            value(s,typepath,type,sizeof type) || strcmp(type,z->type)) return fail();
        if (temp>max[z->group]) max[z->group]=temp;
    }
    struct oneios_thermal_sample sample={
        .id=s->id,.seq=s->seq+1,.ms=began,
        .cpu_mc=max[0],.gpu_mc=max[1],.ddr_mc=max[2]
    };
    if (!max[0] || !max[1] || !max[2] ||
        read_number(s,"/sys/class/power_supply/battery/temp",1200,&sample.battery_dc) ||
        read_number(s,"/sys/class/power_supply/battery/lrp",1200,&sample.lrp_dc) ||
        read_number(s,"/sys/class/sec/sec-ap-thermistor/temperature",1200,&sample.board_ap_dc) ||
        !boot_matches(s) || now_ms(&ended) || ended<began ||
        ended-began>ONEIOS_THERMAL_MAX_SAMPLE_AGE_MS) return fail();
    s->seq=sample.seq; s->last_ms=began; *out=sample;
    return 0;
}
enum oneios_thermal_result oneios_stock_source_tick(
    struct oneios_raw_source *s,struct oneios_thermal_controller *c,
    const struct oneios_thermal_native_sample *native)
{
    if (!c || !c->ready || !c->stock_managed) return ONEIOS_THERMAL_REFUSED;
    if (c->fault) return c->fault_result;
    struct oneios_thermal_sample raw;
    /* Never promote a failed read to a fresh heartbeat or a cold sample. */
    return oneios_thermal_controller_tick_stock(c,
        oneios_raw_source_read(s,&raw) ? NULL : &raw,native);
}
