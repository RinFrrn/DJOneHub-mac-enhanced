/* Read-only ICCID query. Private stdout is consumed by the traffic meter. */
#include <dlfcn.h>
#include <pthread.h>

static void sim_query_log(const char *message)
{
    ssize_t written = write(STDERR_FILENO, message, strlen(message));
    (void)written;
}

static void sim_indication(void *client, unsigned int message, void *buffer,
                           unsigned int length, void *context)
{
    (void)client; (void)message; (void)buffer; (void)length; (void)context;
}

static int sim_identity(void)
{
    void *services = dlopen("libqmiservices.so.1", RTLD_NOW | RTLD_LOCAL);
    void *library = dlopen("libqmi_cci.so.1", RTLD_NOW | RTLD_LOCAL);
    void *(*object)(int32_t,int32_t,int32_t) = NULL;
    int (*init)(void *,unsigned int,void (*)(void *,unsigned int,void *,unsigned int,void *),void *,void *,uint32_t,void **) = NULL;
    int (*send)(void *,unsigned int,void *,unsigned int,void *,unsigned int,unsigned int *,unsigned int) = NULL;
    int (*release)(void *) = NULL;
    struct { uint32_t sig_set,timed_out,clock; pthread_cond_t cond; pthread_condattr_t attr; pthread_mutex_t mutex; } params;
    void *client = NULL, *service = NULL, *symbol;
    unsigned int minor,tool,length = 0U,offset;
    uint8_t response[512];
    uint8_t request = 0;
    char digits[23];
    int result = EXIT_FAILURE, ok = 0;
    if (services == NULL || library == NULL) goto done;
    symbol = dlsym(services,"dms_get_service_object_internal_v01"); memcpy(&object,&symbol,sizeof(object));
    symbol = dlsym(library,"qmi_client_init_instance"); memcpy(&init,&symbol,sizeof(init));
    symbol = dlsym(library,"qmi_client_send_raw_msg_sync"); memcpy(&send,&symbol,sizeof(send));
    symbol = dlsym(library,"qmi_client_release"); memcpy(&release,&symbol,sizeof(release));
    if (!object || !init || !send || !release) goto done;
    sim_query_log("sim-query: service lookup\n");
    for (tool=1U; tool<=8U && service==NULL; ++tool) {
        for (minor=0U; minor<=255U && service==NULL; ++minor) service=object(1,(int32_t)minor,(int32_t)tool);
    }
    if (service==NULL) goto done;
    sim_query_log("sim-query: client init\n");
    memset(&params,0,sizeof(params));
    if (init(service,0xffffU,sim_indication,NULL,&params,3000U,&client)!=0 || client==NULL) goto done;
    sim_query_log("sim-query: read ICCID\n");
    if (send(client,0x3cU,&request,0U,response,sizeof(response),&length,3000U)!=0 || length>sizeof(response)) goto done;
    memset(digits,0,sizeof(digits));
    for (offset=0U; offset+3U<=length;) {
        unsigned int type=response[offset],size=(unsigned int)response[offset+1U] | ((unsigned int)response[offset+2U]<<8U);
        unsigned int i;
        offset+=3U;
        if (size>length-offset) goto done;
        if (type==2U && size==4U && response[offset]==0U && response[offset+1U]==0U) ok=1;
        if (type==1U) {
            if (size<19U || size>20U) goto done;
            for (i=0U;i<size;++i)
                if (response[offset+i]<'0' || response[offset+i]>'9') goto done;
            memcpy(digits,response+offset,size);
        }
        offset+=size;
    }
    if (ok && strlen(digits)>=19U && digits[0]=='8' && digits[1]=='9') { (void)printf("%s\n",digits); result=EXIT_SUCCESS; }
done:
    sim_query_log("sim-query: release\n");
    if (client!=NULL && release!=NULL) (void)release(client);
    /* QCCI worker threads can outlive release. Keep libraries mapped until exit. */
    return result;
}
